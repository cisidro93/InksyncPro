import Foundation
import SwiftData
import SwiftUI

@Model final class SDPageModel: Identifiable {
    @Attribute(.unique) var id: UUID
    var pdfID: UUID
    var pageIndex: Int
    var panelsData: Data?
    var proposedPanelsData: Data?
    var coordinateSystemRaw: String
    
    init(id: UUID = UUID(), pdfID: UUID, pageIndex: Int, coordinateSystemRaw: String, panelsData: Data? = nil, proposedPanelsData: Data? = nil) {
        self.id = id
        self.pdfID = pdfID
        self.pageIndex = pageIndex
        self.coordinateSystemRaw = coordinateSystemRaw
        self.panelsData = panelsData
        self.proposedPanelsData = proposedPanelsData
    }
    
    func toDTO() -> PageModel {
        var panels: [NormalizedRect] = []
        var proposedPanels: [NormalizedRect] = []
        
        let decoder = JSONDecoder()
        if let data = panelsData, let decoded = try? decoder.decode([NormalizedRect].self, from: data) {
            panels = decoded
        }
        if let data = proposedPanelsData, let decoded = try? decoder.decode([NormalizedRect].self, from: data) {
            proposedPanels = decoded
        }
        
        let coord = PageCoordinateSystem(rawValue: coordinateSystemRaw) ?? .unknown
        
        return PageModel(id: id, pageIndex: pageIndex, panels: panels, proposedPanels: proposedPanels, coordinateSystem: coord)
    }
    
    func update(from dto: PageModel) {
        self.pageIndex = dto.pageIndex
        self.coordinateSystemRaw = dto.coordinateSystem.rawValue
        
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(dto.panels) {
            self.panelsData = data
        }
        if let data = try? encoder.encode(dto.proposedPanels) {
            self.proposedPanelsData = data
        }
    }
}

@MainActor
class PageModelStore: ObservableObject {
    static let shared = PageModelStore()
    
    private var modelContext: ModelContext?
    
    // In-Memory cache for the *currently open* comic to prevent SQLite spam during rapid scrolling
    @Published private var activeCache: [Int: PageModel] = [:]
    private var activePDFID: UUID? = nil
    
    private init() {}
    
    func initialize(with context: ModelContext) {
        self.modelContext = context
    }
    
    /// Pre-loads only the bound pages for a specific comic.
    /// This prevents the 10,000 global app panels from loading into RAM on Launch.
    func loadPDFContext(pdfID: UUID) {
        guard activePDFID != pdfID else { return } // Already loaded
        self.activePDFID = pdfID
        self.activeCache.removeAll()
        
        guard let context = modelContext else { return }
        
        // Fetch all pages for this specific PDF
        let fetchDescriptor = FetchDescriptor<SDPageModel>(predicate: #Predicate { $0.pdfID == pdfID })
        if let results = try? context.fetch(fetchDescriptor) {
            for sdModel in results {
                activeCache[sdModel.pageIndex] = sdModel.toDTO()
            }
        }
    }
    
    /// Generates or fetches a precise page model.
    func getPageModel(for pdfID: UUID, pageIndex: Int) -> PageModel {
        // Ensure cache is aligned
        if activePDFID != pdfID {
            loadPDFContext(pdfID: pdfID)
        }
        
        if let model = activeCache[pageIndex] {
            return model
        }
        
        // Generate blank/default
        let newModel = PageModel(pageIndex: pageIndex)
        return newModel
    }
    
    /// Commits panel geometry natively to SQLite without freezing the global hierarchy
    func savePageModel(_ model: PageModel, for pdfID: UUID) {
        // Ensure cache is aligned
        if activePDFID != pdfID {
            loadPDFContext(pdfID: pdfID)
        }
        
        // 1. Update active runtime cache
        // Validate coordinate bounds safely
        var modelToSave = model
        if modelToSave.coordinateSystem == .unknown && !modelToSave.panels.isEmpty {
            modelToSave.coordinateSystem = .normalized
        }
        activeCache[modelToSave.pageIndex] = modelToSave
        
        // 2. Commit to disk asynchronously-ish (ModelContext is synchronous but we defer heavy lifting)
        guard let context = modelContext else { return }
        
        let pageIdx = modelToSave.pageIndex
        // Search for existing
        let descriptor = FetchDescriptor<SDPageModel>(predicate: #Predicate { $0.pdfID == pdfID && $0.pageIndex == pageIdx })
        
        if let existing = try? context.fetch(descriptor), let target = existing.first {
            // Update
            target.update(from: modelToSave)
        } else {
            // Insert new
            let sdModel = SDPageModel(pdfID: pdfID, pageIndex: modelToSave.pageIndex, coordinateSystemRaw: modelToSave.coordinateSystem.rawValue)
            sdModel.update(from: modelToSave)
            context.insert(sdModel)
        }
        
        try? context.save()
    }
    
    /// Legacy hook compatibility for Export injections
    func legacyVisionPanels(for pdfID: UUID, pageIndex: Int) -> [PanelExtractor.Panel] {
        let model = getPageModel(for: pdfID, pageIndex: pageIndex)
        return model.panels.map { rect -> PanelExtractor.Panel in
            let x = rect.origin.x / 1000.0
            let y = rect.origin.y / 1000.0
            let w = rect.width / 1000.0
            let h = rect.height / 1000.0
            
            // Flip Y back to Vision (Bottom-Left)
            let yVision = 1.0 - y - h
            let visionRect = CGRect(x: x, y: yVision, width: w, height: h)
            return PanelExtractor.Panel(boundingBox: visionRect)
        }
    }
    
    /// Returns the number of pages with Guided View data for a specific document
    func getEditedPageCount(for pdfID: UUID) -> Int {
        guard let context = modelContext else { return 0 }
        let descriptor = FetchDescriptor<SDPageModel>(predicate: #Predicate { $0.pdfID == pdfID })
        return (try? context.fetchCount(descriptor)) ?? 0
    }
}

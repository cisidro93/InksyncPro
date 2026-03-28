import SwiftUI
import Vision
import Foundation

@MainActor
class WorkspaceSessionManager: ObservableObject {
    static let shared = WorkspaceSessionManager()
    
    // Guided View Data
    @Published var panelOverrides: [UUID: [Int: [PanelExtractor.Panel]]] = [:]
    
    // Panel Editor State
    @Published var isPresentingPanelEditor: Bool = false
    @Published var currentEditorImage: UIImage? = nil
    @Published var currentEditorPanels: [CGRect] = []
    var panelEditorContinuation: CheckedContinuation<[CGRect], Never>?
    
    func submitPanelEdits(_ panels: [CGRect]) {
        if let continuation = panelEditorContinuation {
            continuation.resume(returning: panels)
            panelEditorContinuation = nil
        }
        isPresentingPanelEditor = false
    }
    
    // Precision Canvas Models (Normalized Coordinates)
    @Published var pageModels: [UUID: [Int: PageModel]] = [:]  
    
    func getPageModel(for pdfID: UUID, pageIndex: Int) -> PageModel {
        if let model = pageModels[pdfID]?[pageIndex] {
            return model
        }
        
        var newModel = PageModel(pageIndex: pageIndex)
        
        if let legacyPanels = panelOverrides[pdfID]?[pageIndex] {
             var allNormalized = true
             newModel.panels = legacyPanels.map { panel in
                let rect = panel.boundingBox
                if rect.maxX <= 1.1 && rect.maxY <= 1.1 {
                     return NormalizedRect(x: rect.minX * 1000, y: rect.minY * 1000, width: rect.width * 1000, height: rect.height * 1000)
                } else {
                     allNormalized = false
                     return NormalizedRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
                }
            }
            
            if !newModel.panels.isEmpty && allNormalized {
                 newModel.coordinateSystem = .normalized
            } else {
                 newModel.coordinateSystem = .unknown 
            }
        }
        return newModel
    }
    
    func savePageModel(_ model: PageModel, for pdfID: UUID) {
        if pageModels[pdfID] == nil { pageModels[pdfID] = [:] }
        var modelToSave = model
        if modelToSave.coordinateSystem == .unknown {
            if !modelToSave.panels.isEmpty {
                modelToSave.coordinateSystem = .normalized
            }
        }
        pageModels[pdfID]?[model.pageIndex] = modelToSave
        
        // Convert back to Vision (Legacy)
        let legacyPanels = model.panels.map { rect -> PanelExtractor.Panel in
            let x = rect.origin.x / 1000.0
            let y = rect.origin.y / 1000.0
            let w = rect.width / 1000.0
            let h = rect.height / 1000.0
            let yVision = 1.0 - y - h
            let visionRect = CGRect(x: x, y: yVision, width: w, height: h)
            return PanelExtractor.Panel(boundingBox: visionRect)
        }
        
        if legacyPanels.isEmpty {
            panelOverrides[pdfID]?[model.pageIndex] = nil 
        } else {
            if panelOverrides[pdfID] == nil {
                panelOverrides[pdfID] = [:]
            }
            panelOverrides[pdfID]?[model.pageIndex] = legacyPanels
        }
        
        // Tell Persistence Manager to save globally
        Task { await MainActor.run { ConversionManager.sharedIfAvailable?.saveLibrary() } }
    }
}

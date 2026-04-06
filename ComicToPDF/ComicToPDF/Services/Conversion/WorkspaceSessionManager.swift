import SwiftUI
import Vision
import Foundation

@MainActor
class WorkspaceSessionManager: ObservableObject {
    static let shared = WorkspaceSessionManager()
    
    // Guided View Data
    // 🗑 panelOverrides RAM dictionary has been migrated to `PageModelStore` native SQLite
    
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
        return PageModelStore.shared.getPageModel(for: pdfID, pageIndex: pageIndex)
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
        
        // Instantly save to Native SQLite Store without bloating the Main Thread
        PageModelStore.shared.savePageModel(modelToSave, for: pdfID)
    }
}

import Foundation
import SwiftUI
import Combine

class PageEditorState: ObservableObject {
    @Published var pageModel: PageModel // ✅ Added missing property
    @Published var selectedPanelIndex: Int?
    @Published var activeTool: WorkAreaToolbar.ToolType = .edit
    @Published var snapGuides: [SnapGuide] = [] // ✅ Magnetic Gutter-Snap
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    @Published var isProcessing: Bool = false
    @Published var debugLog: [String] = [] // ✅ User Request: Error Log
    /// Raw scan output retained for the developer overlay (confidence scores, method badges).
    /// Parallel-indexed with pageModel.proposedPanels.
    @Published var proposedCandidates: [PanelCandidate] = []
    
    private var undoManager: UndoManager
    
    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        debugLog.append("[\(timestamp)] \(message)")
        // Keep log size manageable
        if debugLog.count > 50 { debugLog.removeFirst() }
    }
    
    init(pageModel: PageModel, undoManager: UndoManager) {
        self.pageModel = pageModel
        self.undoManager = undoManager
        
        // Listen to UndoManager to update UI
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(undoManagerChanged),
            name: .NSUndoManagerCheckpoint,
            object: undoManager
        )
        NotificationCenter.default.addObserver(
             self,
             selector: #selector(undoManagerChanged),
             name: .NSUndoManagerDidUndoChange,
             object: undoManager
         )
         NotificationCenter.default.addObserver(
             self,
             selector: #selector(undoManagerChanged),
             name: .NSUndoManagerDidRedoChange,
             object: undoManager
         )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func undoManagerChanged() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
    }
    
    // MARK: - Actions
    
    func execute(_ command: PageCommand) {
        // Register undo operation
        undoManager.registerUndo(withTarget: self) { target in
            command.undo(to: &target.pageModel)
            // Register redo when undoing
            target.undoManager.registerUndo(withTarget: target) { redoTarget in
                command.apply(to: &redoTarget.pageModel)
                // Cycle continues...
            }
        }
        
        // Apply command
        command.apply(to: &pageModel)
        undoManagerChanged()
        
        // Log it
        if case .commitProposals(let p) = command {
            log("Committed \(p.count) proposals")
        } else {
            log("Executed command") // Generic log for now, could be more specific
        }
    }
    
    func undo() {
        undoManager.undo()
        undoManagerChanged()
    }
    
    func redo() {
        undoManager.redo()
        undoManagerChanged()
    }
    
    // MARK: - AI Helpers
    
    func commitProposals() {
        guard !pageModel.proposedPanels.isEmpty else { return }
        let command = PageCommand.commitProposals(pageModel.proposedPanels)
        execute(command)
    }
    
    func clearProposals() {
        pageModel.proposedPanels.removeAll()
    }
}

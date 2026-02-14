import Foundation
import SwiftUI
import Combine

class PageEditorState: ObservableObject {
    @Published var pageModel: PageModel
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    @Published var isProcessing: Bool = false
    
    private var undoManager: UndoManager
    
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

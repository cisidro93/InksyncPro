import Foundation

enum PageCommand {
    case addPanel(NormalizedRect)
    case removePanel(index: Int, rect: NormalizedRect)
    case movePanel(index: Int, oldRect: NormalizedRect, newRect: NormalizedRect)
    case resizePanel(index: Int, oldRect: NormalizedRect, newRect: NormalizedRect)
    case commitProposals([NormalizedRect]) // Turning AI suggestions into real panels
    
    // In a real Command pattern, we might have execute/undo methods here,
    // but since we are using struct-based state (PageModel), we can just have a function
    // that takes a PageModel and returns a new one.
    
    func apply(to model: inout PageModel) {
        switch self {
        case .addPanel(let rect):
            model.panels.append(rect)
            AdaptiveLearningManager.shared.recordUserAddedPanel(size: CGSize(width: rect.width, height: rect.height))
            
        case .removePanel(let index, let rect):
            guard index >= 0 && index < model.panels.count else { return }
            model.panels.remove(at: index)
            AdaptiveLearningManager.shared.recordUserDeletedPanel(size: CGSize(width: rect.width, height: rect.height))
            
        case .movePanel(let index, _, let newRect):
            guard index >= 0 && index < model.panels.count else { return }
            model.panels[index] = newRect
            
        case .resizePanel(let index, _, let newRect):
            guard index >= 0 && index < model.panels.count else { return }
            model.panels[index] = newRect
            
        case .commitProposals(let proposals):
            model.panels.append(contentsOf: proposals)
            model.proposedPanels.removeAll()
        }
    }
    
    func undo(to model: inout PageModel) {
        switch self {
        case .addPanel(let rect):
            model.panels.removeLast()
            // Undoing an add is effectively a delete
            AdaptiveLearningManager.shared.recordUserDeletedPanel(size: CGSize(width: rect.width, height: rect.height))
            
        case .removePanel(let index, let rect):
            if index <= model.panels.count {
                model.panels.insert(rect, at: index)
            } else {
                 model.panels.append(rect)
            }
            // Undoing a delete is effectively an add
            AdaptiveLearningManager.shared.recordUserAddedPanel(size: CGSize(width: rect.width, height: rect.height))
            
        case .movePanel(let index, let oldRect, _):
            guard index >= 0 && index < model.panels.count else { return }
            model.panels[index] = oldRect
            
        case .resizePanel(let index, let oldRect, _):
            guard index >= 0 && index < model.panels.count else { return }
            model.panels[index] = oldRect
            
        case .commitProposals(let proposals):
            // Undo commit = remove the added panels and put them back in proposals
            let count = proposals.count
            let start = model.panels.count - count
            if start >= 0 {
                model.panels.removeSubrange(start..<model.panels.count)
            }
            model.proposedPanels = proposals
        }
    }
}

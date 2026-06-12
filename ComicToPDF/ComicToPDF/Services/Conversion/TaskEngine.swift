import Foundation
import SwiftUI
import Combine

@MainActor
class TaskEngine: ObservableObject {
    static let shared = TaskEngine()
    
    @Published var isConverting = false
    @Published var conversionProgress: Double = 0.0
    @Published var processingStatus = ""
    @Published var statusMessage: String?
    @Published var appAlert: AppAlert?
    @Published var activeTasks: [AppBackgroundTask] = []
    
    func updateTaskProgress(id: UUID, progress: Double) {
        if let idx = activeTasks.firstIndex(where: { $0.id == id }) {
            activeTasks[idx].progress = progress
        }
    }
    
    private var progressSubscription: AnyCancellable?
    
    init() {
        progressSubscription = ConversionEngine.shared.progressSubject.subject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleEngineEvent(event)
            }
    }
    
    private func handleEngineEvent(_ event: ConversionProgressEvent) {
        switch event {
        case .started(let file):
            self.isConverting = true
            self.processingStatus = "Starting: \(file.lastPathComponent)"
        case .progress(_, let current, let total, let message):
            self.conversionProgress = Double(current) / Double(total)
            self.processingStatus = message
        case .completed(_, _):
            self.isConverting = false
            self.processingStatus = ""
            NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil, userInfo: nil)
        case .failed(_, let error):
            self.isConverting = false
            self.appAlert = AppAlert(title: "Conversion Failed", message: error.localizedDescription)
        }
    }
}

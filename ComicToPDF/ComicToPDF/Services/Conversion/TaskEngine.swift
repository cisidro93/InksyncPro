import Foundation
import SwiftUI
import Combine

@MainActor
class TaskEngine: ObservableObject {
    static let shared = TaskEngine()
    
    // MARK: - Conversion State FSM
    public enum ConversionState: Sendable, Equatable {
        case idle
        case converting(file: URL, progress: Double, message: String)
        case completed(outputFile: URL?)
        case failed(errorDescription: String)
    }

    @Published public private(set) var conversionState: ConversionState = .idle
    @Published var isConverting = false
    @Published var conversionProgress: Double = 0.0
    @Published var processingStatus = ""
    @Published var appAlert: AppAlert?
    @Published var activeTasks: [AppBackgroundTask] = []
    
    private var autoDismissTask: Task<Void, Never>? = nil

    @Published var statusMessage: String? {
        didSet {
            autoDismissTask?.cancel()
            if let msg = statusMessage, !msg.isEmpty {
                if msg.contains("Complete") || msg.contains("Ready") || msg.starts(with: "✅") {
                    autoDismissTask = Task {
                        try? await Task.sleep(nanoseconds: 3_500_000_000) // 3.5 seconds
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.statusMessage = nil
                            self.processingStatus = ""
                            self.conversionProgress = 0.0
                        }
                    }
                }
            }
        }
    }
    
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
            self.conversionState = .converting(file: file, progress: 0.0, message: "Starting: \(file.lastPathComponent)")
            self.isConverting = true
            self.processingStatus = "Starting: \(file.lastPathComponent)"
        case .progress(let file, let current, let total, let message):
            let prog = Double(current) / Double(total)
            self.conversionProgress = prog
            self.processingStatus = message
            self.conversionState = .converting(file: file, progress: prog, message: message)
        case .completed(_, let outURL):
            self.isConverting = false
            self.processingStatus = ""
            self.conversionState = .completed(outputFile: outURL)
            NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil, userInfo: nil)
        case .failed(_, let error):
            self.isConverting = false
            self.conversionState = .failed(errorDescription: error.localizedDescription)
            self.appAlert = AppAlert(title: "Conversion Failed", message: error.localizedDescription)
        }
    }
}

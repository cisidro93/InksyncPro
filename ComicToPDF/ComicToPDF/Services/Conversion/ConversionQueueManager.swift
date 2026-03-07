import SwiftUI
import Combine

/// A global, background-safe queue for processing massive files asynchronously.
/// This prevents `@MainActor` from locking the UI during heavy E-Ink conversions.
class ConversionQueueManager: ObservableObject {
    static let shared = ConversionQueueManager()
    
    struct QueueItem: Identifiable, Equatable {
        let id = UUID()
        let sourceURL: URL
        let settings: ConversionSettings
        let mode: UIMode
        
        enum UIMode: Equatable {
            case go
            case pro
        }
    }
    
    @Published var queue: [QueueItem] = []
    @Published var activeItem: QueueItem? = nil
    @Published var isProcessing: Bool = false
    @Published var currentProgress: Double = 0.0
    @Published var statusMessage: String = ""
    
    // ✅ NEW: Queue Timer State
    @Published var queueStartTime: Date? = nil
    @Published var elapsedTime: TimeInterval = 0.0
    @Published var estimatedTimeRemaining: TimeInterval? = nil
    
    // Internal Timer tracked variables
    private var initialQueueCount: Int = 0
    private var completedItemsCount: Int = 0
    
    private var processingTask: Task<Void, Never>?
    private var progressSubscription: AnyCancellable?
    private var timerCancellable: AnyCancellable?
    
    private init() {
        // Listen to the shared raw engine to extract real-time progress
        progressSubscription = ConversionEngine.shared.progressSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleEngineEvent(event)
            }
    }
    
    /// Enqueues a file for conversion. If the queue is idle, it starts processing immediately.
    func enqueue(url: URL, settings: ConversionSettings, mode: QueueItem.UIMode) {
        let item = QueueItem(sourceURL: url, settings: settings, mode: mode)
        queue.append(item)
        
        if !isProcessing {
            // New Batch starting
            initialQueueCount = queue.count
            completedItemsCount = 0
            startTimer()
            processNext()
        } else {
            // Append to existing batch (re-calculate total)
            initialQueueCount += 1
        }
    }
    
    /// Cancels either the currently active conversion or clears the entire queue.
    func cancelAll() {
        processingTask?.cancel()
        queue.removeAll()
        activeItem = nil
        isProcessing = false
        currentProgress = 0.0
        statusMessage = "Cancelled"
        stopTimer()
    }
    
    private func processNext() {
        guard !queue.isEmpty else {
            isProcessing = false
            activeItem = nil
            statusMessage = "Queue complete."
            stopTimer()
            
            // Tell the main manager to rescan the library when the queue finishes
            Task { @MainActor in
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRescan"), object: nil)
            }
            return
        }
        
        isProcessing = true
        let item = queue.removeFirst()
        activeItem = item
        currentProgress = 0.0
        statusMessage = "Preparing \(item.sourceURL.lastPathComponent)..."
        
        // Spawn detached background task to prevent ANY main thread locking
        processingTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            do {
                _ = try await ConversionEngine.shared.process(url: item.sourceURL, settings: item.settings)
                
                await MainActor.run {
                    self.processNext()
                }
                
            } catch {
                if Task.isCancelled {
                    await MainActor.run {
                        Logger.shared.log("Task Cancelled: \(item.sourceURL.lastPathComponent)", category: "Queue", type: .warning)
                        self.statusMessage = "Conversion Cancelled"
                        self.isProcessing = false
                    }
                } else {
                    await MainActor.run {
                        Logger.shared.log("Pipeline Error processing \(item.sourceURL.lastPathComponent): \(error.localizedDescription)", category: "Queue", type: .error)
                        self.processNext() // Skip failed item and move to next
                    }
                }
            }
        }
    }
    
    private func handleEngineEvent(_ event: ConversionProgressEvent) {
        switch event {
        case .started(let file):
            self.statusMessage = "Processing \(file.lastPathComponent)..."
        case .progress(_, let current, let total, let message):
            self.currentProgress = Double(current) / Double(total)
            self.statusMessage = message
        case .completed(_, _):
            self.statusMessage = "Finishing up..."
            self.completedItemsCount += 1
        case .failed(_, let error):
            self.statusMessage = "Error: \(error.localizedDescription)"
            self.completedItemsCount += 1 // Count as completed to prevent ETR from stalling
        }
    }
    
    // MARK: - Queue Timer Methods
    
    private func startTimer() {
        queueStartTime = Date()
        elapsedTime = 0.0
        estimatedTimeRemaining = nil
        
        timerCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let startTime = self.queueStartTime else { return }
                
                // 1. Update Elapsed Time
                self.elapsedTime = Date().timeIntervalSince(startTime)
                
                // 2. Calculate ETR
                let totalJobs = Double(self.initialQueueCount)
                let completedJobs = Double(self.completedItemsCount)
                let currentItemProgress = max(0.0, min(1.0, self.currentProgress))
                
                let totalProgress = completedJobs + currentItemProgress
                
                // Wait until at least one item has made 5% progress or 3 seconds have passed to avoid chaotic early estimations
                if totalProgress > 0.05 {
                    let timePerJob = self.elapsedTime / totalProgress
                    let remainingJobs = totalJobs - totalProgress
                    self.estimatedTimeRemaining = timePerJob * remainingJobs
                }
            }
    }
    
    private func stopTimer() {
        timerCancellable?.cancel()
        timerCancellable = nil
        queueStartTime = nil
    }
}

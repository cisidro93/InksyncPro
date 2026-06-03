import Foundation

/// Represents a queued conversion job for a file that is currently being downloaded or waiting for background execution.
struct ConversionJob: Codable, Identifiable, Sendable {
    let id: UUID
    let pdfID: UUID // The ID of the ConvertedPDF in the library
    let targetFileName: String
    let outputName: String? // For merges
    let mangaMode: Bool?
    let settings: ConversionSettings
    let isMerge: Bool
    var status: JobStatus
    
    enum JobStatus: String, Codable {
        case waitingForDownload
        case extracting
        case merging
        case suspended
        case completed
        case failed
    }
}

/// A thread-safe, persistent queue for tracking Cloud-to-Kindle conversions across app launches.
@MainActor
class ConversionJobQueue: ObservableObject {
    static let shared = ConversionJobQueue()
    
    @Published private(set) var jobs: [ConversionJob] = []
    private let queueURL: URL
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        queueURL = appSupport.appendingPathComponent("conversion_jobs.json")
        loadJobs()
    }
    
    // MARK: - Public API
    
    func enqueueJob(pdfID: UUID, targetFileName: String, outputName: String? = nil, mangaMode: Bool?, settings: ConversionSettings, isMerge: Bool = false) {
        let job = ConversionJob(
            id: UUID(),
            pdfID: pdfID,
            targetFileName: targetFileName,
            outputName: outputName,
            mangaMode: mangaMode,
            settings: settings,
            isMerge: isMerge,
            status: .waitingForDownload
        )
        Logger.shared.log("ConversionJobQueue: enqueued job for '\(targetFileName)' (pdfID=\(pdfID), merge=\(isMerge))", category: "ConversionQueue", type: .info)
        
        self.jobs.append(job)
        let currentJobs = self.jobs
        let url = queueURL
        Task.detached(priority: .background) {
            Self.saveJobs(currentJobs, to: url)
        }
    }
    
    func updateJobStatus(pdfID: UUID, newStatus: ConversionJob.JobStatus) {
        if let index = jobs.firstIndex(where: { $0.pdfID == pdfID }) {
            let oldStatus = jobs[index].status
            jobs[index].status = newStatus
            let currentJobs = jobs
            let url = queueURL
            Task.detached(priority: .background) {
                Self.saveJobs(currentJobs, to: url)
            }
            Logger.shared.log("ConversionJobQueue: status \(oldStatus.rawValue) → \(newStatus.rawValue) for pdfID=\(pdfID)", category: "ConversionQueue", type: .info)
        } else {
            Logger.shared.log("ConversionJobQueue: updateJobStatus — no job found for pdfID=\(pdfID)", category: "ConversionQueue", type: .warning)
        }
    }
    
    func removeJob(pdfID: UUID) {
        Logger.shared.log("ConversionJobQueue: removing job for pdfID=\(pdfID)", category: "ConversionQueue", type: .info)
        jobs.removeAll(where: { $0.pdfID == pdfID })
        let currentJobs = jobs
        let url = queueURL
        Task.detached(priority: .background) {
            Self.saveJobs(currentJobs, to: url)
        }
    }
    
    func getJob(for pdfID: UUID) -> ConversionJob? {
        return self.jobs.first(where: { $0.pdfID == pdfID })
    }
    
    func getJobByTargetFileName(_ name: String) -> ConversionJob? {
        return self.jobs.first(where: { $0.targetFileName == name })
    }
    
    // MARK: - Persistence
    
    private func loadJobs() {
        guard let data = try? Data(contentsOf: queueURL),
              let loadedJobs = try? JSONDecoder().decode([ConversionJob].self, from: data) else {
            Logger.shared.log("ConversionJobQueue: no persisted queue found (fresh start)", category: "ConversionQueue", type: .info)
            return
        }
        Logger.shared.log("ConversionJobQueue: loaded \(loadedJobs.count) persisted job(s)", category: "ConversionQueue", type: .success)
        self.jobs = loadedJobs
    }
    
    nonisolated private static func saveJobs(_ newJobs: [ConversionJob], to url: URL) {
        if let data = try? JSONEncoder().encode(newJobs) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                Logger.shared.log("ConversionJobQueue: saveJobs FAILED: \(error.localizedDescription)", category: "ConversionQueue", type: .error)
            }
        } else {
            Logger.shared.log("ConversionJobQueue: JSON encoding of jobs failed", category: "ConversionQueue", type: .error)
        }
    }
}

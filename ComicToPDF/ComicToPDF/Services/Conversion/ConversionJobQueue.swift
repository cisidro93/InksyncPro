import Foundation

/// Represents a queued conversion job for a file that is currently being downloaded or waiting for background execution.
struct ConversionJob: Codable, Identifiable {
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
class ConversionJobQueue: ObservableObject {
    static let shared = ConversionJobQueue()
    
    @Published private(set) var jobs: [ConversionJob] = []
    private let queueURL: URL
    private let queueQueue = DispatchQueue(label: "com.antigravity.InksyncPro.ConversionJobQueue")
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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
        queueQueue.async {
            var currentJobs = self.jobs
            currentJobs.append(job)
            self.saveJobs(currentJobs)
        }
    }
    
    func updateJobStatus(pdfID: UUID, newStatus: ConversionJob.JobStatus) {
        queueQueue.async {
            var currentJobs = self.jobs
            if let index = currentJobs.firstIndex(where: { $0.pdfID == pdfID }) {
                let oldStatus = currentJobs[index].status
                currentJobs[index].status = newStatus
                self.saveJobs(currentJobs)
                Logger.shared.log("ConversionJobQueue: status \(oldStatus.rawValue) → \(newStatus.rawValue) for pdfID=\(pdfID)", category: "ConversionQueue", type: .info)
            } else {
                Logger.shared.log("ConversionJobQueue: updateJobStatus — no job found for pdfID=\(pdfID)", category: "ConversionQueue", type: .warning)
            }
        }
    }
    
    func removeJob(pdfID: UUID) {
        Logger.shared.log("ConversionJobQueue: removing job for pdfID=\(pdfID)", category: "ConversionQueue", type: .info)
        queueQueue.async {
            var currentJobs = self.jobs
            currentJobs.removeAll(where: { $0.pdfID == pdfID })
            self.saveJobs(currentJobs)
        }
    }
    
    func getJob(for pdfID: UUID) -> ConversionJob? {
        return queueQueue.sync {
            return self.jobs.first(where: { $0.pdfID == pdfID })
        }
    }
    
    func getJobByTargetFileName(_ name: String) -> ConversionJob? {
        return queueQueue.sync {
            return self.jobs.first(where: { $0.targetFileName == name })
        }
    }
    
    // MARK: - Persistence
    
    private func loadJobs() {
        queueQueue.sync {
            guard let data = try? Data(contentsOf: queueURL),
                  let loadedJobs = try? JSONDecoder().decode([ConversionJob].self, from: data) else {
                Logger.shared.log("ConversionJobQueue: no persisted queue found (fresh start)", category: "ConversionQueue", type: .info)
                return
            }
            Logger.shared.log("ConversionJobQueue: loaded \(loadedJobs.count) persisted job(s)", category: "ConversionQueue", type: .success)
            DispatchQueue.main.async { self.jobs = loadedJobs }
        }
    }
    
    private func saveJobs(_ newJobs: [ConversionJob]) {
        if let data = try? JSONEncoder().encode(newJobs) {
            do {
                try data.write(to: queueURL, options: .atomic)
            } catch {
                Logger.shared.log("ConversionJobQueue: saveJobs FAILED: \(error.localizedDescription)", category: "ConversionQueue", type: .error)
            }
        } else {
            Logger.shared.log("ConversionJobQueue: JSON encoding of jobs failed", category: "ConversionQueue", type: .error)
        }
        DispatchQueue.main.async { self.jobs = newJobs }
    }
}

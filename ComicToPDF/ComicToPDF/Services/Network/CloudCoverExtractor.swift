import Foundation
import UIKit

// Actor-isolated cloud cover extractor.
// Max 2 concurrent downloads via AsyncSemaphore.
// Skips files already in-flight. 15s per-request timeout.
// Writes covers atomically via PhysicalFileSystemRouter pattern.

actor CloudCoverExtractor {
    static let shared = CloudCoverExtractor()

    private var inFlight: Set<UUID> = []
    private let maxConcurrent = 2
    private var activeTasks = 0

    private init() {}

    // MARK: - Public API

    func extract(for pdfs: [ConvertedPDF]) async {
        await withTaskGroup(of: Void.self) { group in
            for pdf in pdfs {
                guard shouldExtract(pdf) else { continue }

                while activeTasks >= maxConcurrent {
                    await Task.yield()
                }
                activeTasks += 1
                inFlight.insert(pdf.id)

                group.addTask { [weak self] in
                    await self?.extractCover(for: pdf)
                }
            }
        }
    }

    // MARK: - Single File Extraction

    private func extractCover(for pdf: ConvertedPDF) async {
        defer {
            inFlight.remove(pdf.id)
            activeTasks -= 1
        }

        guard case .cloud(let provider, let remoteID) = pdf.sourceMode,
              provider == "Dropbox" else { return }

        do {
            let manifest = try await withTimeout(seconds: 15) {
                let downloadURL = try await DropboxProvider.shared.getDownloadURL(fileID: remoteID)
                return try await ZipCentralDirectory.fetch(from: downloadURL, authHeader: nil)
            }

            guard let coverEntry = manifest.pageEntries.first else {
                Logger.shared.log("CloudCoverExtractor: No page entries in \(pdf.name)", category: "Cloud", type: .warning)
                return
            }

            let imageData = try await withTimeout(seconds: 15) {
                try await ZipCentralDirectory.fetchEntryData(entry: coverEntry, manifest: manifest)
            }

            guard let image = UIImage(data: imageData),
                  let thumbnail = image.preparingThumbnail(of: CGSize(width: 360, height: 540)) else {
                Logger.shared.log("CloudCoverExtractor: Could not decode cover image for \(pdf.name)", category: "Cloud", type: .error)
                return
            }

            guard let jpegData = thumbnail.jpegData(compressionQuality: 0.85) else { return }

            // Atomic write via tmp→replaceItem
            let coverURL = PhysicalFileSystemRouter.getCoversDirectory()
                .appendingPathComponent("cover_\(pdf.id.uuidString).jpg")
            let tmpURL = PhysicalFileSystemRouter.getCoversDirectory()
                .appendingPathComponent("cover_\(pdf.id.uuidString).tmp.jpg")

            try jpegData.write(to: tmpURL)
            _ = try FileManager.default.replaceItemAt(coverURL, withItemAt: tmpURL)

            Logger.shared.log("CloudCoverExtractor: Cover extracted for \(pdf.name)", category: "Cloud")

        } catch {
            Logger.shared.log("CloudCoverExtractor: Failed for \(pdf.name) — \(error.localizedDescription)", category: "Cloud", type: .error)
        }
    }

    // MARK: - Guard

    private func shouldExtract(_ pdf: ConvertedPDF) -> Bool {
        guard !inFlight.contains(pdf.id) else { return false }
        guard case .cloud(let provider, _) = pdf.sourceMode, provider == "Dropbox" else { return false }

        let coverURL = PhysicalFileSystemRouter.getCoversDirectory()
            .appendingPathComponent("cover_\(pdf.id.uuidString).jpg")
        return !FileManager.default.fileExists(atPath: coverURL.path)
    }
}

// MARK: - withTimeout Helper

private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw URLError(.timedOut)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

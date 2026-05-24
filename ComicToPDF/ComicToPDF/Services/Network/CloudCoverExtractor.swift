import Foundation
import UIKit

// Actor-isolated cloud cover extractor.
// Max 2 concurrent downloads via AsyncSemaphore.
// Skips files already in-flight. 15s per-request timeout.
// Writes covers atomically (tmp→replaceItem pattern).
//
// SUPPORTED FORMATS:
//   CBZ (.cbz, .zip)  — ZIP Central Directory byte-range parse (no full download)
//   CBR (.cbr)        — RAR4/RAR5 header parse; stored entries extracted in-place;
//                       compressed entries fall back gracefully (logged, skipped)
//
// DROPBOX LINK LIFETIME:
//   get_temporary_link URLs expire after exactly 4 hours.
//   A fresh link is fetched per extraction job. Never cache a link across jobs.

actor CloudCoverExtractor {
    static let shared = CloudCoverExtractor()

    private var inFlight: Set<UUID> = []
    // Parking semaphore — replaces the Task.yield() spin-loop which burns CPU under contention.
    private let semaphore = CCESemaphore(limit: 2)

    private init() {}

    // Nonisolated: safe to call from inside actor without @MainActor crossing.
    private nonisolated func coversDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Covers")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Public API

    func extract(for pdfs: [ConvertedPDF]) async {
        await withTaskGroup(of: Void.self) { group in
            for pdf in pdfs {
                guard shouldExtract(pdf) else { continue }
                inFlight.insert(pdf.id)

                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.semaphore.wait()
                    defer { Task { await self.semaphore.signal() } }
                    await self.extractCover(for: pdf)
                }
            }
        }
    }

    // MARK: - ConversionManager reference for streaming fallback
    // Weak so we never keep the manager alive longer than the app.
    private weak var conversionManagerRef: ConversionManager?

    /// Call once at startup to wire the streaming fallback.
    func setConversionManager(_ manager: ConversionManager) {
        conversionManagerRef = manager
    }

    // MARK: - Single File Extraction (format-aware router)

    private func extractCover(for pdf: ConvertedPDF) async {
        defer { inFlight.remove(pdf.id) }

        guard case .cloud(let provider, let remoteID) = pdf.sourceMode else { return }

        let ext = (pdf.name as NSString).pathExtension.lowercased()

        do {
            // ── Step 1: Get a fresh temporary link and potential auth header ──
            let downloadURL: URL
            let authHeader: String?

            if provider == "Dropbox" {
                downloadURL = try await withTimeout(seconds: 15) {
                    try await DropboxProvider.shared.getDownloadURL(fileID: remoteID)
                }
                authHeader = nil
            } else if provider == "Google Drive" || provider == "GoogleDrive" {
                downloadURL = try await withTimeout(seconds: 15) {
                    try await GoogleDriveProvider.shared.getDownloadURL(fileID: remoteID)
                }
                authHeader = try await GoogleDriveProvider.shared.currentAuthHeader()
            } else {
                return
            }

            // ── Step 2: Extract cover image based on archive format ────────────
            let imageData: Data

            switch ext {
            case "cbz", "zip":
                imageData = try await extractFromZip(url: downloadURL, authHeader: authHeader, pdfName: pdf.name)

            case "cbr":
                imageData = try await extractFromRar(url: downloadURL, authHeader: authHeader, pdfName: pdf.name, pdf: pdf)

            default:
                Logger.shared.log(
                    "CloudCoverExtractor: Unsupported format '.\(ext)' for \(pdf.name) — skipping",
                    category: "Cloud", type: .warning
                )
                return
            }

            // ── Step 3: Decode → thumbnail ────────────────────────────────────
            guard let image = UIImage(data: imageData),
                  let thumbnail = image.preparingThumbnail(of: CGSize(width: 360, height: 540)) else {
                Logger.shared.log(
                    "CloudCoverExtractor: Could not decode cover image for \(pdf.name)",
                    category: "Cloud", type: .error
                )
                return
            }

            guard let jpegData = thumbnail.jpegData(compressionQuality: 0.85) else { return }

            // ── Step 4: Atomic write ──────────────────────────────────────────
            let coversDir = coversDirectory()
            let coverURL  = coversDir.appendingPathComponent("cover_\(pdf.id.uuidString).jpg")
            let tmpURL    = coversDir.appendingPathComponent("cover_\(pdf.id.uuidString).tmp.jpg")

            try jpegData.write(to: tmpURL)
            _ = try FileManager.default.replaceItemAt(coverURL, withItemAt: tmpURL)

            // ── Step 5: Invalidate NSCache + wake SwiftUI cells ───────────────
            // CloudCoverExtractor writes directly to disk without going through
            // saveCoverImage(). We must manually post the notification so cells
            // re-render — otherwise they stay on the cloud placeholder forever.
            let pdfID = pdf.id
            let finalImage = thumbnail
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .cloudCoverReady,
                    object: nil,
                    userInfo: ["pdfID": pdfID, "image": finalImage]
                )
            }

            Logger.shared.log(
                "CloudCoverExtractor: [\(ext.uppercased())] Cover extracted for \(pdf.name)",
                category: "Cloud"
            )

        } catch {
            Logger.shared.log(
                "CloudCoverExtractor: Failed for \(pdf.name) — \(error.localizedDescription)",
                category: "Cloud", type: .error
            )
        }
    }

    // MARK: - Format Extractors

    /// CBZ / ZIP: parse the Central Directory from the file's tail (no full download).
    private func extractFromZip(url: URL, authHeader: String?, pdfName: String) async throws -> Data {
        let manifest = try await withTimeout(seconds: 15) {
            try await ZipCentralDirectory.fetch(from: url, authHeader: authHeader)
        }
        guard let coverEntry = manifest.pageEntries.first else {
            throw NSError(domain: "CloudCoverExtractor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No page images in ZIP: \(pdfName)"])
        }
        return try await withTimeout(seconds: 15) {
            try await ZipCentralDirectory.fetchEntryData(entry: coverEntry, manifest: manifest)
        }
    }

    /// CBR / RAR: parse sequential block headers from the file's head.
    /// Stored (method 0x30) entries are fetched byte-range directly.
    /// Compressed entries fall back to a full-file stream + local extraction.
    private func extractFromRar(url: URL, authHeader: String?, pdfName: String, pdf: ConvertedPDF) async throws -> Data {
        let entry = try await withTimeout(seconds: 15) {
            try await RARHeaderParser.fetchFirstEntry(from: url, authHeader: authHeader)
        }

        if entry.isStored {
            // Fast path: byte-range fetch for uncompressed images
            return try await withTimeout(seconds: 15) {
                try await RARHeaderParser.fetchEntryData(entry: entry, from: url, authHeader: authHeader)
            }
        } else {
            // Slow path: full download → local UnrarKit extraction.
            // Most CBRs use RAR-compressed images; byte-range is not possible without decompression.
            Logger.shared.log(
                "CloudCoverExtractor: CBR '\(pdfName)' uses compressed RAR — falling back to full-file stream.",
                category: "Cloud", type: .info
            )
            let localURL = try await CloudDownloadManager.shared.streamCloudFile(pdf: pdf)
            defer { try? FileManager.default.removeItem(at: localURL) }

            guard let image = PhysicalFileSystemRouter.extractCoverImageStatic(from: localURL),
                  let data = image.jpegData(compressionQuality: 0.85) else {
                throw NSError(domain: "CloudCoverExtractor", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Could not extract cover from downloaded CBR: \(pdfName)"])
            }
            return data
        }
    }

    // MARK: - Guard

    private func shouldExtract(_ pdf: ConvertedPDF) -> Bool {
        guard !inFlight.contains(pdf.id) else { return false }
        guard case .cloud(let provider, _) = pdf.sourceMode, ["Dropbox", "GoogleDrive", "Google Drive"].contains(provider) else { return false }

        let ext = (pdf.name as NSString).pathExtension.lowercased()
        guard ["cbz", "zip", "cbr"].contains(ext) else { return false }

        let coverURL = coversDirectory()
            .appendingPathComponent("cover_\(pdf.id.uuidString).jpg")
        return !FileManager.default.fileExists(atPath: coverURL.path)
    }
}

// MARK: - withTimeout Helper

private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
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

// MARK: - Parking semaphore (CloudCoverExtractor-scoped, avoids cross-layer dependency)
// Named CCESemaphore to prevent collision with the AsyncSemaphore in LibraryGridRows.
private actor CCESemaphore {
    private let limit: Int
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func wait() async {
        if count < limit { count += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            count = max(0, count - 1)
        }
    }
}

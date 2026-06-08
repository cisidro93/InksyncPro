import Foundation

// MARK: - CloudReadyState
// Describes how the reader should open a cloud file.
//
//  .pageStream      → instant open via per-page byte-range fetches (OPDS-style)
//                     Used for: CBZ / ZIP / EPUB
//
//  .extractedPages  → pages extracted to temp dir, served as local file:// URLs
//                     Used for: CBR / RAR (download + extract, then identical to local)
//
//  .localTemp       → full archive downloaded to temp dir, reader extracts itself
//                     Used for: malformed ZIPs, CB7, CBT, unsupported formats

enum CloudReadyState {
    case pageStream(CloudPageSource)
    case extractedPages(workingDir: URL, pages: [URL])
    case localTemp(URL)
}

// MARK: - CloudPageSource

struct CloudPageSource {
    let manifest: ZipManifest
    var pages: [ZipEntry] { manifest.pageEntries }
    var pageCount: Int    { pages.count }
}

// MARK: - CloudStreamCoordinator

@MainActor
final class CloudStreamCoordinator: ObservableObject {
    static let shared = CloudStreamCoordinator()
    private init() {}

    // MARK: - Phase

    enum Phase: Equatable {
        case idle
        case resolvingURL           // Getting auth'd download URL from provider
        case fetchingIndex          // Fetching ZIP central directory (~50ms)
        case downloading(Double)    // CBR: full download progress 0–1
        case extracting(Double)     // CBR: extracting pages from archive 0–1
        case ready
        case failed(String)
    }

    @Published var phase: Phase = .idle

    // MARK: - Public API

    func prepare(pdf: ConvertedPDF) async throws -> CloudReadyState {
        guard case .cloud(let provider, _) = pdf.sourceMode else {
            throw CloudCoordinatorError.notACloudFile
        }

        await MainActor.run { self.phase = .resolvingURL }

        // ── Step 1: Resolve authenticated download URL ───────────────────────────
        let downloadURL: URL
        // authHeader is set per-provider below and never mutated after assignment,
        // so `let` is correct. Using `var` triggers a Swift immutability warning.
        let authHeader: String? = nil

        if provider == "Dropbox" {
            downloadURL = try await DropboxProvider.shared.getDownloadURL(fileID: archiveRemoteID(pdf))
        } else {
            throw CloudCoordinatorError.unknownProvider(provider)
        }

        // ── Step 2: Route by file extension ─────────────────────────────────────
        let ext = (pdf.name as NSString).pathExtension.lowercased()

        switch ext {
        case "cbz", "zip", "epub":
            return try await preparePageStream(url: downloadURL, authHeader: authHeader, pdf: pdf)
        case "cbr", "rar":
            return try await prepareCBRStream(url: downloadURL, authHeader: authHeader, pdf: pdf)
        default:
            // CB7, CBT, unknown — full download, reader extracts
            return try await prepareGenericFallback(pdf: pdf)
        }
    }

    // MARK: - Page-Stream Path (ZIP / CBZ / EPUB → instant open)

    private func preparePageStream(url: URL, authHeader: String?, pdf: ConvertedPDF) async throws -> CloudReadyState {
        await MainActor.run { self.phase = .fetchingIndex }

        do {
            let manifest = try await ZipCentralDirectory.fetch(from: url, authHeader: authHeader)

            guard manifest.pageEntries.count > 0 else {
                Logger.shared.log("CloudStreamCoordinator: No pages in '\(pdf.name)' — falling back", category: "Cloud", type: .error)
                return try await prepareGenericFallback(pdf: pdf)
            }

            await MainActor.run { self.phase = .ready }
            Logger.shared.log(
                "CloudStreamCoordinator: '\(pdf.name)' → page-stream (\(manifest.pageEntries.count) pages)",
                category: "Cloud", type: .success
            )
            return .pageStream(CloudPageSource(manifest: manifest))

        } catch ZipCentralDirectoryError.eocdNotFound,
                ZipCentralDirectoryError.invalidCentralDirectory {
            Logger.shared.log("CloudStreamCoordinator: ZIP parse failed for '\(pdf.name)' — falling back", category: "Cloud", type: .error)
            return try await prepareGenericFallback(pdf: pdf)
        }
    }

    // MARK: - CBR / RAR Path (Download → Extract → Serve local page URLs)
    //
    // Storage footprint is kept minimal:
    //   - CBR temp file is deleted IMMEDIATELY after extraction completes.
    //   - Peak storage = extracted pages only (~1× file size).
    //   - Background CBZ repack only runs if ≥2× file size of free space is available.
    //   - Extracted pages directory lives in NSTemporaryDirectory — OS evicts on pressure.

    private func prepareCBRStream(url: URL, authHeader: String?, pdf: ConvertedPDF) async throws -> CloudReadyState {

        // ── A: Download to temp ───────────────────────────────────────────────────
        await MainActor.run { self.phase = .downloading(0.0) }
        let localCBR = try await CloudDownloadManager.shared.streamCloudFile(pdf: pdf)
        let cbrAttrs = try? FileManager.default.attributesOfItem(atPath: localCBR.path)
        let cbrFileSize: Int64 = (cbrAttrs?[.size] as? Int64) ?? 0

        // Guard: bail immediately on an empty file — avoids Unrar Error 2 on 0-byte bodies
        guard cbrFileSize > 0 else {
            try? FileManager.default.removeItem(at: localCBR)
            CloudDownloadManager.shared.evictCache(for: archiveRemoteID(pdf))
            throw CloudCoordinatorError.emptyArchive
        }

        // ── B: Attempt RAR extraction ─────────────────────────────────────────────
        await MainActor.run { self.phase = .extracting(0.0) }
        Logger.shared.log("CloudStreamCoordinator: Extracting CBR '\(pdf.name)'…", category: "Cloud")

        // `fileToCleanUp` tracks whichever local file we ultimately own so cleanup is exact.
        var fileToCleanUp: URL = localCBR

        do {
            // Happy path: genuine RAR archive
            let (workingDir, pages) = try await CBRExtractor.extract(from: localCBR)

            try? FileManager.default.removeItem(at: fileToCleanUp)
            CloudDownloadManager.shared.evictCache(for: archiveRemoteID(pdf))
            await MainActor.run { self.phase = .ready }

            Logger.shared.log("CloudStreamCoordinator: '\(pdf.name)' → \(pages.count) RAR pages extracted", category: "Cloud", type: .success)

            scheduleRepackIfPossible(workingDir: workingDir, fileSize: cbrFileSize, pdfName: pdf.name)
            return .extractedPages(workingDir: workingDir, pages: pages)

        } catch {
            // ── C: ZIP-masquerading-as-CBR fallback ──────────────────────────────
            // Unrar Error 2 (ERAR_BAD_DATA) fires when libunrar sees a ZIP magic number.
            // Rather than extracting locally, try the byte-range stream path first — it
            // opens instantly and writes nothing to disk.
            Logger.shared.log(
                "CloudStreamCoordinator: CBR failed (\(error.localizedDescription)) — checking if mislabelled ZIP…",
                category: "Cloud", type: .warning
            )

            // Rename to .cbz so ZipCentralDirectory can fetch the EOCD
            let fallbackCBZ = localCBR.deletingPathExtension().appendingPathExtension("cbz")
            do {
                try FileManager.default.moveItem(at: localCBR, to: fallbackCBZ)
                fileToCleanUp = fallbackCBZ   // ← ownership transferred
            } catch {
                // Rename failed (e.g. destination already exists). Clean up and surface original error.
                try? FileManager.default.removeItem(at: localCBR)
                CloudDownloadManager.shared.evictCache(for: archiveRemoteID(pdf))
                throw error
            }

            do {
                // ✅ Best-case: parse the ZIP central directory and return an instant page-stream.
                // This writes ZERO bytes to disk — identical to a normal CBZ open.
                let manifest = try await ZipCentralDirectory.fetch(from: url, authHeader: authHeader)
                guard manifest.pageEntries.count > 0 else { throw CloudCoordinatorError.emptyArchive }

                try? FileManager.default.removeItem(at: fileToCleanUp)
                CloudDownloadManager.shared.evictCache(for: archiveRemoteID(pdf))
                await MainActor.run { self.phase = .ready }

                Logger.shared.log(
                    "CloudStreamCoordinator: '\(pdf.name)' is a mislabelled ZIP → page-stream (\(manifest.pageEntries.count) pages)",
                    category: "Cloud", type: .success
                )
                return .pageStream(CloudPageSource(manifest: manifest))

            } catch {
                // Page-stream also failed — try local extraction of the renamed .cbz
                do {
                    let (workingDir, pages) = try await ZipUtilities.extractComic(from: fallbackCBZ)
                    try? FileManager.default.removeItem(at: fileToCleanUp)
                    CloudDownloadManager.shared.evictCache(for: archiveRemoteID(pdf))
                    await MainActor.run { self.phase = .ready }

                    Logger.shared.log(
                        "CloudStreamCoordinator: '\(pdf.name)' mislabelled ZIP extracted locally (\(pages.count) pages)",
                        category: "Cloud", type: .success
                    )
                    scheduleRepackIfPossible(workingDir: workingDir, fileSize: cbrFileSize, pdfName: pdf.name)
                    return .extractedPages(workingDir: workingDir, pages: pages)

                } catch {
                    // All paths exhausted — file is genuinely corrupt or unsupported
                    try? FileManager.default.removeItem(at: fileToCleanUp)
                    CloudDownloadManager.shared.evictCache(for: archiveRemoteID(pdf))
                    throw error
                }
            }
        }
    }

    /// Schedule a background ZIP repack of extracted images if storage headroom allows.
    /// Uses `ZipUtilities.zipDirectory` directly on the already-extracted working dir,
    /// NOT `CBRExtractor.convertToCBZ` (which expects an archive source, not a directory).
    private func scheduleRepackIfPossible(workingDir: URL, fileSize: Int64, pdfName: String) {
        Task(priority: .background) {
            let freeSpace = availableDiskSpace()
            guard freeSpace > fileSize * 2 else {
                Logger.shared.log(
                    "CloudStreamCoordinator: CBZ repack skipped — only \(freeSpace / 1_048_576)MB free",
                    category: "Cloud"
                )
                return
            }
            do {
                let cbzURL = workingDir.appendingPathComponent("\(pdfName).cbz")
                try await ZipUtilities.zipDirectory(workingDir, to: cbzURL)
                Logger.shared.log(
                    "CloudStreamCoordinator: '\(pdfName)' silently repacked to CBZ",
                    category: "Cloud", type: .success
                )
            } catch {
                Logger.shared.log(
                    "CloudStreamCoordinator: CBZ repack skipped: \(error.localizedDescription)",
                    category: "Cloud"
                )
            }
        }
    }

    /// Returns available bytes in the temporary directory's volume.
    private func availableDiskSpace() -> Int64 {
        let tmp = FileManager.default.temporaryDirectory
        let values = try? tmp.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: - Generic Fallback (CB7, CBT, malformed ZIP)

    private func prepareGenericFallback(pdf: ConvertedPDF) async throws -> CloudReadyState {
        let localURL = try await CloudDownloadManager.shared.streamCloudFile(pdf: pdf)
        await MainActor.run { self.phase = .ready }
        return .localTemp(localURL)
    }

    // MARK: - Helpers

    private func archiveRemoteID(_ pdf: ConvertedPDF) -> String {
        if case .cloud(_, let id) = pdf.sourceMode { return id }
        return ""
    }
}

// MARK: - CloudCoordinatorError

enum CloudCoordinatorError: LocalizedError {
    case notACloudFile
    case unknownProvider(String)
    case noPages
    case emptyArchive

    var errorDescription: String? {
        switch self {
        case .notACloudFile:
            return "This file is stored locally and does not require cloud streaming."
        case .unknownProvider(let name):
            return "'\(name)' is not a supported cloud provider. Please reconnect in Settings."
        case .noPages:
            return "No readable pages were found in this archive."
        case .emptyArchive:
            return "The archive downloaded from the cloud was empty (0 bytes). Check your connection and try again."
        }
    }
}

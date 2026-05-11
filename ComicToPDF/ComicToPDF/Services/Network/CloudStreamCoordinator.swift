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
        var authHeader: String? = nil

        if provider == "Dropbox" {
            downloadURL = try await DropboxProvider.shared.getDownloadURL(fileID: archiveRemoteID(pdf))
        } else if provider == "Google Drive" {
            downloadURL = try await GoogleDriveProvider.shared.getDownloadURL(fileID: archiveRemoteID(pdf))
            authHeader  = try await GoogleDriveProvider.shared.currentAuthHeader()
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

        // ── A: Download CBR to temp ──────────────────────────────────────────────
        await MainActor.run { self.phase = .downloading(0.0) }
        let localCBR = try await CloudDownloadManager.shared.streamCloudFile(pdf: pdf)
        let cbrFileSize = (try? FileManager.default.attributesOfItem(atPath: localCBR.path)[.size] as? Int64) ?? 0

        // ── B: Extract pages, then DELETE the source CBR immediately ─────────────
        await MainActor.run { self.phase = .extracting(0.0) }
        Logger.shared.log("CloudStreamCoordinator: Extracting CBR '\(pdf.name)'…", category: "Cloud")

        let (workingDir, pages) = try await CBRExtractor.extract(from: localCBR)

        // ✅ Storage clean-up: source CBR is no longer needed — delete it right away.
        // Peak storage now = extracted pages only (~1× original file size).
        try? FileManager.default.removeItem(at: localCBR)
        // Also evict it from CloudDownloadManager's temp cache to prevent re-use of a deleted path
        await MainActor.run {
            if case .cloud(_, let remoteID) = pdf.sourceMode {
                CloudDownloadManager.shared.evictCache(for: remoteID)
            }
        }

        await MainActor.run { self.phase = .ready }
        Logger.shared.log(
            "CloudStreamCoordinator: '\(pdf.name)' → \(pages.count) pages extracted (CBR deleted)",
            category: "Cloud", type: .success
        )

        // ── C: Background CBZ repack — only if storage headroom allows ───────────
        // Require ≥2× the original file size of free space so we don't pressure the device.
        Task(priority: .background) {
            let freeSpace = availableDiskSpace()
            let requiredSpace = cbrFileSize * 2
            guard freeSpace > requiredSpace else {
                Logger.shared.log(
                    "CloudStreamCoordinator: CBZ repack skipped — insufficient free space (\(freeSpace / 1_048_576)MB free, need \(requiredSpace / 1_048_576)MB)",
                    category: "Cloud"
                )
                return
            }
            do {
                let cbzURL = workingDir.appendingPathComponent("\(pdf.name).cbz")
                let repacked = try await CBRExtractor.convertToCBZ(from: workingDir, destination: cbzURL)
                Logger.shared.log(
                    "CloudStreamCoordinator: CBR silently repacked → '\(repacked.lastPathComponent)'",
                    category: "Cloud", type: .success
                )
            } catch {
                Logger.shared.log(
                    "CloudStreamCoordinator: CBZ repack skipped: \(error.localizedDescription)",
                    category: "Cloud"
                )
            }
        }

        return .extractedPages(workingDir: workingDir, pages: pages)
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

    var errorDescription: String? {
        switch self {
        case .notACloudFile:
            return "This file is stored locally and does not require cloud streaming."
        case .unknownProvider(let name):
            return "'\(name)' is not a supported cloud provider. Please reconnect in Settings."
        case .noPages:
            return "No readable pages were found in this archive."
        }
    }
}

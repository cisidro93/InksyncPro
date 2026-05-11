import Foundation

// MARK: - CloudReadyState
// Describes how the reader should open a cloud file.
// .pageStream → instant open via per-page byte-range fetches (OPDS-style)
// .localTemp  → full archive downloaded to temp dir first (CBR/RAR fallback)

enum CloudReadyState {
    case pageStream(CloudPageSource)
    case localTemp(URL)
}

// MARK: - CloudPageSource
// Carries everything ComicImageCache needs to perform per-page byte-range fetches
// against the remote archive — without any local file.

struct CloudPageSource {
    let manifest: ZipManifest
    /// Image-only entries in natural reading order, ready to index as page 0, 1, 2...
    var pages: [ZipEntry] { manifest.pageEntries }
    var pageCount: Int    { pages.count }
}

// MARK: - CloudStreamCoordinator
// Single entry point for all cloud reader preparation.
// Detects archive format, chooses the optimal streaming strategy, and
// returns a `CloudReadyState` that ReaderView uses to initialise the reader.

@MainActor
final class CloudStreamCoordinator: ObservableObject {
    static let shared = CloudStreamCoordinator()
    private init() {}

    // MARK: - Published Preparation State
    // Observers (e.g. CloudAwareLoadingView) can display the right messaging
    // based on which phase the coordinator is in.
    enum Phase: Equatable {
        case idle
        case resolvingURL          // Getting auth'd download URL from provider
        case fetchingIndex         // Fetching ZIP central directory (~50ms)
        case streaming(Double)     // Fallback path: full download progress 0–1
        case ready
        case failed(String)
    }

    @Published var phase: Phase = .idle

    // MARK: - Public API

    /// Prepare a cloud file for reading.
    /// - Returns: `.pageStream` for ZIP-family formats (instant),
    ///            `.localTemp` for RAR/7z/other (full download required).
    func prepare(pdf: ConvertedPDF) async throws -> CloudReadyState {
        guard case .cloud(let provider, let remoteID) = pdf.sourceMode else {
            // Local file — caller should not use this coordinator
            throw CloudCoordinatorError.notACloudFile
        }

        await MainActor.run { self.phase = .resolvingURL }

        // ── Step 1: Resolve the download URL + auth header from the provider ──
        let downloadURL: URL
        var authHeader: String? = nil

        if provider == "Dropbox" {
            downloadURL = try await DropboxProvider.shared.getDownloadURL(fileID: remoteID)
            // Dropbox temporary links are pre-authenticated — no header needed
        } else if provider == "Google Drive" {
            downloadURL = try await GoogleDriveProvider.shared.getDownloadURL(fileID: remoteID)
            authHeader  = try await GoogleDriveProvider.shared.currentAuthHeader()
        } else {
            throw CloudCoordinatorError.unknownProvider(provider)
        }

        // ── Step 2: Route by file extension ───────────────────────────────────
        let ext = pdf.name.components(separatedBy: ".").last?.lowercased() ?? ""
        let supportsPageStream = ["cbz", "zip", "epub"].contains(ext)

        if supportsPageStream {
            return try await preparePageStream(
                url: downloadURL,
                authHeader: authHeader,
                pdf: pdf
            )
        } else {
            // CBR, CB7, CBT → fall back to full-archive streaming
            return try await prepareFallbackStream(
                provider: provider,
                remoteID: remoteID,
                pdf: pdf
            )
        }
    }

    // MARK: - Private: Page-Stream Path (ZIP central directory)

    private func preparePageStream(url: URL, authHeader: String?, pdf: ConvertedPDF) async throws -> CloudReadyState {
        await MainActor.run { self.phase = .fetchingIndex }

        do {
            let manifest = try await ZipCentralDirectory.fetch(from: url, authHeader: authHeader)

            guard manifest.pageEntries.count > 0 else {
                // No image entries found — could be a corrupt or unusual archive
                Logger.shared.log(
                    "CloudStreamCoordinator: No page images found in '\(pdf.name)'. Falling back.",
                    category: "Cloud", type: .error
                )
                // Try full download as last resort
                return try await prepareFallbackStream(provider: archiveProvider(pdf), remoteID: archiveRemoteID(pdf), pdf: pdf)
            }

            await MainActor.run { self.phase = .ready }

            Logger.shared.log(
                "CloudStreamCoordinator: '\(pdf.name)' → page stream ready (\(manifest.pageEntries.count) pages)",
                category: "Cloud", type: .success
            )

            return .pageStream(CloudPageSource(manifest: manifest))

        } catch ZipCentralDirectoryError.eocdNotFound,
                ZipCentralDirectoryError.invalidCentralDirectory {
            // Malformed ZIP — fall back to full download
            Logger.shared.log(
                "CloudStreamCoordinator: ZIP index parse failed for '\(pdf.name)'. Falling back to full stream.",
                category: "Cloud", type: .error
            )
            return try await prepareFallbackStream(provider: archiveProvider(pdf), remoteID: archiveRemoteID(pdf), pdf: pdf)
        }
    }

    // MARK: - Private: Fallback Full-Stream Path (CBR / malformed ZIP)

    private func prepareFallbackStream(provider: String, remoteID: String, pdf: ConvertedPDF) async throws -> CloudReadyState {
        // Observe progress from CloudDownloadManager and relay it here
        let localURL = try await CloudDownloadManager.shared.streamCloudFile(pdf: pdf)
        await MainActor.run { self.phase = .ready }
        return .localTemp(localURL)
    }

    // MARK: - Helpers

    private func archiveProvider(_ pdf: ConvertedPDF) -> String {
        if case .cloud(let p, _) = pdf.sourceMode { return p }
        return ""
    }

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

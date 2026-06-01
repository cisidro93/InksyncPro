import Foundation
import Unrar

// MARK: - CBR Extractor
// Wraps the Unrar.swift package to extract RAR-based comic archives (.cbr, .rar).
// Produces the same (workingDir, imageURLs) tuple as ZipUtilities for drop-in compatibility.

struct CBRExtractor {

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff"]

    /// Extracts a CBR/RAR archive to a temporary directory.
    /// - Returns: (workingDir, sorted image URLs) — same contract as ZipUtilities.extractComic
    static func extract(from sourceURL: URL) async throws -> (workingDir: URL, imageURLs: [URL]) {
        let fileManager = FileManager.default

        // ── Phase 1: Resolve local file URL ────────────────────────────────────
        // Unrar.Archive calls into libunrar which uses fopen() internally.
        // fopen() only accepts local filesystem paths — passing an https:// URL
        // returns ERAR_BAD_DATA (error 2). Download remote files to a temp path first.
        let localSourceURL: URL
        var tempDownloadURL: URL? = nil
        let scheme = sourceURL.scheme?.lowercased() ?? ""

        if scheme == "http" || scheme == "https" {
            Logger.shared.log(
                "CBRExtractor: remote CBR detected — downloading to temp file before extraction",
                category: "System"
            )
            let downloadDest = fileManager.temporaryDirectory
                .appendingPathComponent("cbr_dl_\(UUID().uuidString).cbr")
            // URLSession.download is natively async — no DispatchQueue bridge needed
            let (downloaded, response) = try await URLSession.shared.download(from: sourceURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(
                    domain: "CBRExtractor", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Remote CBR download failed (HTTP \(http.statusCode))"]
                )
            }
            try fileManager.moveItem(at: downloaded, to: downloadDest)
            localSourceURL = downloadDest
            tempDownloadURL = downloadDest
        } else {
            localSourceURL = sourceURL
        }
        
        let finalTempDownloadURL = tempDownloadURL

        // ── Phase 2: Sync RAR extraction on a background thread ────────────────
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                do {
                    // Security-scoped access (only applies to local sandbox-scoped URLs)
                    let secured = localSourceURL.startAccessingSecurityScopedResource()
                    defer {
                        if secured { localSourceURL.stopAccessingSecurityScopedResource() }
                        // Clean up the temporary downloaded file after extraction
                        if let tmp = finalTempDownloadURL { try? fm.removeItem(at: tmp) }
                    }

                    // Create extraction destination
                    let stem = sourceURL.deletingPathExtension().lastPathComponent
                    let uniqueID = UUID().uuidString.prefix(8)
                    let tempDir = fm.temporaryDirectory
                        .appendingPathComponent("cbr_\(stem)_\(uniqueID)")
                    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

                    // Open archive — Unrar.Archive disambiguates from ZIPFoundation.Archive
                    let archive = try Unrar.Archive(fileURL: localSourceURL)

                    // List all entries
                    let entries = try archive.entries()
                    var imageURLs: [URL] = []

                    for entry in entries {
                        let flatName = (entry.fileName as NSString).lastPathComponent

                        // Skip directories and macOS metadata artefacts
                        guard !entry.directory,
                              !entry.fileName.contains("__MACOSX"),
                              !flatName.hasPrefix("._"),
                              flatName != ".DS_Store" else { continue }

                        let ext = (flatName as NSString).pathExtension.lowercased()
                        guard imageExtensions.contains(ext) else { continue }

                        // Flatten the path — all images land directly in tempDir
                        let destURL = tempDir.appendingPathComponent(flatName)

                        try autoreleasepool {
                            // Extract entry to Data then persist atomically
                            let data = try archive.extract(entry)
                            try data.write(to: destURL, options: .atomic)
                            imageURLs.append(destURL)
                        }
                    }

                    guard !imageURLs.isEmpty else {
                        throw CBRError.noImagesFound
                    }

                    // Sort alphanumerically — same contract as ZipUtilities
                    let sorted = imageURLs.sorted {
                        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                    }

                    Logger.shared.log(
                        "CBRExtractor: unpacked \(sorted.count) images from \(sourceURL.lastPathComponent)",
                        category: "System", type: .success
                    )
                    continuation.resume(returning: (tempDir, sorted))

                } catch {
                    Logger.shared.log(
                        "CBRExtractor failed: \(error.localizedDescription)",
                        category: "System", type: .error
                    )
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - CBR-to-CBZ Repackager
    /// Extracts a CBR and repacks images into a CBZ so future reads are zero-overhead.
    static func convertToCBZ(from sourceURL: URL, destination: URL? = nil) async throws -> URL {
        let (workingDir, imageURLs) = try await extract(from: sourceURL)
        defer { try? FileManager.default.removeItem(at: workingDir) }

        let destURL = destination ?? sourceURL
            .deletingPathExtension()
            .appendingPathExtension("cbz")

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }

        let imagesDir = imageURLs.first?.deletingLastPathComponent() ?? workingDir
        try await ZipUtilities.zipDirectory(imagesDir, to: destURL)

        Logger.shared.log(
            "CBRExtractor: \(sourceURL.lastPathComponent) \u{2192} \(destURL.lastPathComponent)",
            category: "System", type: .success
        )
        return destURL
    }
}

// MARK: - CBR Errors

enum CBRError: LocalizedError {
    case noImagesFound
    case archiveOpenFailed(String)

    var errorDescription: String? {
        switch self {
        case .noImagesFound:
            return "No images were found inside the CBR archive."
        case .archiveOpenFailed(let msg):
            return "Could not open the CBR archive: \(msg)"
        }
    }
}

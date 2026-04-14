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
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let fileManager = FileManager.default

                    // Security-scoped access
                    let secured = sourceURL.startAccessingSecurityScopedResource()
                    defer { if secured { sourceURL.stopAccessingSecurityScopedResource() } }

                    // Create temp destination
                    let stem = sourceURL.deletingPathExtension().lastPathComponent
                    let uniqueID = UUID().uuidString.prefix(8)
                    let tempDir = fileManager.temporaryDirectory
                        .appendingPathComponent("cbr_\(stem)_\(uniqueID)")
                    try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

                    // Open archive — Unrar.Archive disambiguates from ZIPFoundation.Archive
                    let archive = try Unrar.Archive(fileURL: sourceURL)

                    // List all entries
                    let entries = try archive.entries()
                    var imageURLs: [URL] = []

                    for entry in entries {
                        // Skip directories and macOS metadata artefacts
                        guard !entry.fileName.hasSuffix("/"),
                              !entry.fileName.contains("__MACOSX"),
                              !entry.fileName.hasPrefix(".") else { continue }

                        let ext = (entry.fileName as NSString).pathExtension.lowercased()
                        guard imageExtensions.contains(ext) else { continue }

                        // Flatten the path — all images land directly in tempDir
                        let flatName = (entry.fileName as NSString).lastPathComponent
                        let destURL = tempDir.appendingPathComponent(flatName)

                        // Extract entry to Data then persist atomically
                        let data = try archive.extract(entry)
                        try data.write(to: destURL, options: .atomic)
                        imageURLs.append(destURL)
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

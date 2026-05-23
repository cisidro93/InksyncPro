import Foundation

// MARK: - CBTExtractor
// Extracts CBT (Comic Book TAR) archives — TAR files renamed with the .cbt extension.
//
// TAR format overview (POSIX ustar / GNU tar, both handled):
//   • The file is a sequence of 512-byte blocks.
//   • Each file entry begins with a 512-byte header block, followed by the file
//     data padded to the next 512-byte boundary.
//   • Two consecutive all-zero 512-byte blocks mark the end of the archive.
//   • All numeric fields in the header are octal ASCII strings.
//
// No external library is required — the format is simple enough to read with
// Foundation's basic Data APIs.

struct CBTExtractor {

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "tiff", "heic"]

    // MARK: - Public API

    /// Extracts a CBT archive to a temporary directory.
    /// - Returns: (workingDir, sorted image URLs) — same contract as ZipUtilities.extractComic
    static func extract(from sourceURL: URL) async throws -> (workingDir: URL, imageURLs: [URL]) {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                do {
                    let secured = sourceURL.startAccessingSecurityScopedResource()
                    defer { if secured { sourceURL.stopAccessingSecurityScopedResource() } }

                    // Read the entire archive into memory.
                    // CBT files are comic archives — typically 50–500 MB, manageable on modern
                    // devices. For very large archives a streaming approach could be added later.
                    let archiveData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)

                    let stem = sourceURL.deletingPathExtension().lastPathComponent
                    let uniqueID = UUID().uuidString.prefix(8)
                    let tempDir = fm.temporaryDirectory
                        .appendingPathComponent("cbt_\(stem)_\(uniqueID)")
                    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

                    let imageURLs = try parseTAR(data: archiveData, into: tempDir)

                    guard !imageURLs.isEmpty else { throw CBTError.noImagesFound }

                    let sorted = imageURLs.sorted {
                        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                    }

                    Logger.shared.log(
                        "CBTExtractor: unpacked \(sorted.count) images from \(sourceURL.lastPathComponent)",
                        category: "System", type: .success
                    )
                    continuation.resume(returning: (tempDir, sorted))

                } catch {
                    Logger.shared.log(
                        "CBTExtractor failed: \(error.localizedDescription)",
                        category: "System", type: .error
                    )
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - TAR Parser

    /// Parses a TAR/ustar archive from raw `data` and writes image files into `destDir`.
    /// Returns the list of written image URLs.
    private static func parseTAR(data: Data, into destDir: URL) throws -> [URL] {
        let blockSize = 512
        var offset = 0
        var imageURLs: [URL] = []
        var consecutiveZeroBlocks = 0

        while offset + blockSize <= data.count {
            let headerBlock = data[offset ..< offset + blockSize]

            // End-of-archive: two consecutive all-zero blocks
            if headerBlock.allSatisfy({ $0 == 0 }) {
                consecutiveZeroBlocks += 1
                if consecutiveZeroBlocks >= 2 { break }
                offset += blockSize
                continue
            }
            consecutiveZeroBlocks = 0

            // Parse header fields (all offsets per POSIX ustar spec)
            guard let name     = tarString(headerBlock, offset: 0,   length: 100),
                  let sizeOctal = tarString(headerBlock, offset: 124, length: 12) else {
                offset += blockSize
                continue
            }

            // File size in bytes (octal ASCII)
            let fileSize = Int(sizeOctal.trimmingCharacters(in: .whitespaces)
                                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")), radix: 8) ?? 0

            // Type flag byte: '0' or '\0' = regular file, '5' = directory
            let typeflag = headerBlock[headerBlock.startIndex + 156]

            // Skip non-regular-file entries (directories, symlinks, etc.)
            let isRegular = typeflag == UInt8(ascii: "0") || typeflag == 0
            if !isRegular || fileSize == 0 {
                let dataBlocks = (fileSize + blockSize - 1) / blockSize
                offset += blockSize + (dataBlocks * blockSize)
                continue
            }

            // ustar prefix field (bytes 345–499 extend the filename for long paths)
            let prefix = tarString(headerBlock, offset: 345, length: 155) ?? ""
            let fullName: String
            if !prefix.isEmpty && !prefix.trimmingCharacters(in: CharacterSet(charactersIn: "\0")).isEmpty {
                let cleanPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                let cleanName   = name.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                fullName = cleanPrefix + "/" + cleanName
            } else {
                fullName = name.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }

            let flatName = (fullName as NSString).lastPathComponent

            // Skip macOS artefacts
            guard !fullName.contains("__MACOSX"),
                  !flatName.hasPrefix("._"),
                  flatName != ".DS_Store" else {
                let dataBlocks = (fileSize + blockSize - 1) / blockSize
                offset += blockSize + (dataBlocks * blockSize)
                continue
            }

            let ext = (flatName as NSString).pathExtension.lowercased()
            let dataStart = offset + blockSize
            let dataBlocks = (fileSize + blockSize - 1) / blockSize
            let dataEnd = dataStart + fileSize

            if imageExtensions.contains(ext), dataEnd <= data.count {
                let fileData = data[dataStart ..< dataEnd]
                let destURL = destDir.appendingPathComponent(flatName)
                try fileData.write(to: destURL, options: .atomic)
                imageURLs.append(destURL)
            }

            offset += blockSize + (dataBlocks * blockSize)
        }

        return imageURLs
    }

    // MARK: - Helpers

    /// Reads a null-terminated ASCII string from `data` at the given byte range.
    private static func tarString(_ data: Data, offset: Int, length: Int) -> String? {
        let start = data.startIndex + offset
        let end = min(start + length, data.endIndex)
        guard start < end else { return nil }
        let slice = data[start ..< end]
        // Trim null bytes — TAR fields are null-padded to their fixed length
        let bytes = slice.prefix(while: { $0 != 0 })
        return String(bytes: bytes, encoding: .utf8)
            ?? String(bytes: bytes, encoding: .isoLatin1)
    }
}

// MARK: - CBT Errors

enum CBTError: LocalizedError {
    case noImagesFound

    var errorDescription: String? {
        switch self {
        case .noImagesFound:
            return "No images were found inside the CBT archive."
        }
    }
}

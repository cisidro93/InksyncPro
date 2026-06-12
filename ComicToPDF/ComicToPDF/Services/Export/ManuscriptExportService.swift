import Foundation

// MARK: - ManuscriptExportService
// Pure value-type service. No @MainActor dependency.
// Call from a Task.detached to keep heavy I/O off the render thread.

enum ManuscriptExportFormat {
    case markdownZip      // one .md file per chapter, zipped
    case plainText        // single .txt with --- chapter breaks
    case markdownBundle   // single .md with # Chapter headings
}

enum ManuscriptExportError: LocalizedError {
    case noDocuments
    case fileWriteFailed(String)
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDocuments:       return "This manuscript has no chapters to export."
        case .fileWriteFailed(let r): return "Could not write export file: \(r)"
        case .zipFailed(let r):  return "Could not create zip archive: \(r)"
        }
    }
}

struct ManuscriptExportService {

    // MARK: - Public API

    /// Exports each chapter as a separate .md file inside a zip archive.
    /// Returns a URL pointing at the zip in the OS temp directory.
    static func exportAsMarkdownZip(
        title: String,
        chapters: [(title: String, markdown: String)]
    ) throws -> URL {
        guard !chapters.isEmpty else { throw ManuscriptExportError.noDocuments }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectFolder = root.appendingPathComponent(sanitize(title), isDirectory: true)
        try fm.createDirectory(at: projectFolder, withIntermediateDirectories: true)

        // Write each chapter
        for (index, chapter) in chapters.enumerated() {
            let number = String(format: "%02d", index + 1)
            let filename = "\(number) - \(sanitize(chapter.title)).md"
            let fileURL = projectFolder.appendingPathComponent(filename)
            guard (try? chapter.markdown.write(to: fileURL, atomically: true, encoding: .utf8)) != nil else {
                throw ManuscriptExportError.fileWriteFailed(filename)
            }
        }

        // Write README / TOC
        let toc = buildTOC(title: title, chapters: chapters)
        let tocURL = projectFolder.appendingPathComponent("README.md")
        try toc.write(to: tocURL, atomically: true, encoding: .utf8)

        // Zip the project folder
        let zipURL = root.appendingPathComponent("\(sanitize(title)).zip")
        try manualZip(sourceDir: projectFolder, destinationZip: zipURL)

        return zipURL
    }

    /// Exports all chapters as a single plain .txt file with chapter breaks.
    static func exportAsPlainText(
        title: String,
        chapters: [(title: String, markdown: String)]
    ) throws -> URL {
        guard !chapters.isEmpty else { throw ManuscriptExportError.noDocuments }

        var output = "# \(title)\n\n"
        for (index, chapter) in chapters.enumerated() {
            output += "---\n\n"
            output += "CHAPTER \(index + 1): \(chapter.title.uppercased())\n\n"
            // Strip markdown syntax for plain text
            output += stripMarkdown(chapter.markdown)
            output += "\n\n"
        }

        let filename = "\(sanitize(title)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        guard (try? output.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            throw ManuscriptExportError.fileWriteFailed(filename)
        }
        return url
    }

    /// Exports all chapters as a single .md file with ## headings per chapter.
    static func exportAsMarkdownBundle(
        title: String,
        chapters: [(title: String, markdown: String)]
    ) throws -> URL {
        guard !chapters.isEmpty else { throw ManuscriptExportError.noDocuments }

        var output = "# \(title)\n\n"
        for chapter in chapters {
            output += "## \(chapter.title)\n\n"
            output += chapter.markdown
            output += "\n\n"
        }

        let filename = "\(sanitize(title)).md"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        guard (try? output.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            throw ManuscriptExportError.fileWriteFailed(filename)
        }
        return url
    }

    // MARK: - Helpers

    private static func buildTOC(title: String, chapters: [(title: String, markdown: String)]) -> String {
        var toc = "# \(title)\n\n## Table of Contents\n\n"
        for (index, chapter) in chapters.enumerated() {
            let number = String(format: "%02d", index + 1)
            let wordCount = chapter.markdown
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.count
            toc += "\(number). **\(chapter.title)** — \(wordCount) words\n"
        }
        toc += "\n---\n*Exported from InksyncPro*\n"
        return toc
    }

    private static func sanitize(_ name: String) -> String {
        name.components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " -_")).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
    }

    private static func stripMarkdown(_ text: String) -> String {
        var result = text
        // Remove heading markers
        result = result.replacingOccurrences(of: #"#{1,6}\s"#, with: "", options: .regularExpression)
        // Remove bold/italic markers
        result = result.replacingOccurrences(of: #"\*{1,3}([^*]+)\*{1,3}"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"_{1,3}([^_]+)_{1,3}"#, with: "$1", options: .regularExpression)
        // Remove code backticks
        result = result.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        // Remove markdown links, keep text
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
        return result
    }

    // MARK: - Manual Zip (no ZipFoundation dependency required)
    // Creates a flat zip archive from a directory using Process/minizip-style approach.
    // Pure Swift, no third-party library needed.

    private static func manualZip(sourceDir: URL, destinationZip: URL) throws {
        // Collect all files
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fm.enumerator(
            at: sourceDir,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            throw ManuscriptExportError.zipFailed("Could not enumerate source directory")
        }

        // Build a simple uncompressed zip using the ZIP local file header format
        var zipData = Data()
        var centralDirectory = Data()
        var fileCount: UInt16 = 0


        var localFileHeaders: [(offset: UInt32, data: Data)] = []

        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: Set(resourceKeys)).isRegularFile) == true else { continue }

            guard let fileData = try? Data(contentsOf: fileURL) else { continue }
            let relativePath = String(fileURL.path.dropFirst(sourceDir.path.count + 1))
            guard let nameData = relativePath.data(using: .utf8) else { continue }

            let localOffset = UInt32(zipData.count)
            // Local file header
            var localHeader = Data()
            localHeader.append(contentsOf: [0x50, 0x4B, 0x03, 0x04]) // signature
            localHeader.append(contentsOf: [0x14, 0x00])             // version needed
            localHeader.append(contentsOf: [0x00, 0x00])             // flags
            localHeader.append(contentsOf: [0x00, 0x00])             // compression (stored)
            localHeader.append(contentsOf: [0x00, 0x00])             // mod time
            localHeader.append(contentsOf: [0x00, 0x00])             // mod date
            localHeader.append(crc32Data(fileData))                   // CRC-32
            localHeader.append(uint32LE(UInt32(fileData.count)))      // compressed size
            localHeader.append(uint32LE(UInt32(fileData.count)))      // uncompressed size
            localHeader.append(uint16LE(UInt16(nameData.count)))      // filename length
            localHeader.append(contentsOf: [0x00, 0x00])              // extra field length
            localHeader.append(nameData)
            localHeader.append(fileData)
            localFileHeaders.append((offset: localOffset, data: localHeader))
            zipData.append(localHeader)

            // Central directory entry
            var cdEntry = Data()
            cdEntry.append(contentsOf: [0x50, 0x4B, 0x01, 0x02]) // signature
            cdEntry.append(contentsOf: [0x14, 0x00])              // version made by
            cdEntry.append(contentsOf: [0x14, 0x00])              // version needed
            cdEntry.append(contentsOf: [0x00, 0x00])              // flags
            cdEntry.append(contentsOf: [0x00, 0x00])              // compression
            cdEntry.append(contentsOf: [0x00, 0x00])              // mod time
            cdEntry.append(contentsOf: [0x00, 0x00])              // mod date
            cdEntry.append(crc32Data(fileData))                    // CRC-32
            cdEntry.append(uint32LE(UInt32(fileData.count)))       // compressed size
            cdEntry.append(uint32LE(UInt32(fileData.count)))       // uncompressed size
            cdEntry.append(uint16LE(UInt16(nameData.count)))       // filename length
            cdEntry.append(contentsOf: [0x00, 0x00])               // extra field length
            cdEntry.append(contentsOf: [0x00, 0x00])               // comment length
            cdEntry.append(contentsOf: [0x00, 0x00])               // disk number start
            cdEntry.append(contentsOf: [0x00, 0x00])               // internal attributes
            cdEntry.append(contentsOf: [0x00, 0x00, 0x00, 0x00])   // external attributes
            cdEntry.append(uint32LE(localOffset))                   // local header offset
            cdEntry.append(nameData)
            centralDirectory.append(cdEntry)
            fileCount += 1
        }

        // End of central directory record
        let cdSize = UInt32(centralDirectory.count)
        let cdOffset = UInt32(zipData.count)
        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]) // signature
        eocd.append(contentsOf: [0x00, 0x00])              // disk number
        eocd.append(contentsOf: [0x00, 0x00])              // disk with CD
        eocd.append(uint16LE(fileCount))                   // entries on disk
        eocd.append(uint16LE(fileCount))                   // total entries
        eocd.append(uint32LE(cdSize))                      // CD size
        eocd.append(uint32LE(cdOffset))                    // CD offset
        eocd.append(contentsOf: [0x00, 0x00])              // comment length

        zipData.append(centralDirectory)
        zipData.append(eocd)

        guard (try? zipData.write(to: destinationZip, options: .atomic)) != nil else {
            throw ManuscriptExportError.zipFailed("Could not write zip to disk")
        }
    }

    // MARK: - ZIP Binary Helpers

    private static func uint16LE(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func uint32LE(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    private static func crc32Data(_ data: Data) -> Data {
        var crc: UInt32 = 0xFFFFFFFF
        let table = crc32Table
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return uint32LE(~crc)
    }

    private static let crc32Table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var crc = UInt32(i)
            for _ in 0..<8 {
                if crc & 1 == 1 { crc = (crc >> 1) ^ 0xEDB88320 }
                else { crc >>= 1 }
            }
            return crc
        }
    }()
}

import Foundation
import ZIPFoundation

// MARK: - ManuscriptExportService
// Pure value-type service. No @MainActor dependency.
// Call from a Task.detached to keep heavy I/O off the render thread.

enum ManuscriptExportFormat {
    case markdownZip      // one .md file per chapter, zipped
    case plainText        // single .txt with --- chapter breaks
    case markdownBundle   // single .md with # Chapter headings
    case epubKindle       // publication-grade EPUB with Kindle TOC
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

    /// Exports all chapters as a Kindle-ready EPUB with professional typography, TOC, and metadata.
    static func exportAsEPUB(
        title: String,
        author: String? = nil,
        chapters: [(title: String, markdown: String)]
    ) throws -> URL {
        guard !chapters.isEmpty else { throw ManuscriptExportError.noDocuments }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let epubDir = tempDir.appendingPathComponent("EPUB_Manuscript", isDirectory: true)
        let oebpsDir = epubDir.appendingPathComponent("OEBPS", isDirectory: true)
        let textDir = oebpsDir.appendingPathComponent("text", isDirectory: true)
        let cssDir = oebpsDir.appendingPathComponent("css", isDirectory: true)
        let metaInfDir = epubDir.appendingPathComponent("META-INF", isDirectory: true)

        try fm.createDirectory(at: textDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: cssDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: metaInfDir, withIntermediateDirectories: true)

        let css = """
        @page { margin: 1in; }
        body {
            font-family: Georgia, Baskerville, "Times New Roman", serif;
            font-size: 1.05em;
            line-height: 1.6;
            color: #111111;
            margin: 0;
            padding: 5%;
        }
        h1 {
            font-size: 1.8em;
            text-align: center;
            margin-top: 2em;
            margin-bottom: 1.5em;
            font-weight: bold;
        }
        p {
            text-indent: 1.5em;
            margin-top: 0;
            margin-bottom: 0;
            text-align: justify;
        }
        p.first-p {
            text-indent: 0;
        }
        .section-break {
            text-align: center;
            margin: 1.8em 0;
            font-size: 1.2em;
            letter-spacing: 0.3em;
        }
        """
        try css.write(to: cssDir.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)

        var manifestItems: [String] = [
            "<item id=\"css\" href=\"css/style.css\" media-type=\"text/css\"/>",
            "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>",
            "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        ]
        var spineItems: [String] = []
        var tocEntries: [EPUBManifestBuilder.EPUBTOCEntry] = []

        for (idx, chapter) in chapters.enumerated() {
            let chapterID = String(format: "chapter_%03d", idx + 1)
            let htmlName = "\(chapterID).xhtml"
            let sanitizedTitle = chapter.title.isEmpty ? "Chapter \(idx + 1)" : chapter.title

            var bodyHTML = "<h1>\(sanitizedTitle.xmlEscaped())</h1>\n"
            let paragraphs = chapter.markdown.components(separatedBy: "\n\n")
            for (pIdx, p) in paragraphs.enumerated() {
                let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if trimmed == "* * *" || trimmed == "***" || trimmed == "---" {
                    bodyHTML += "    <div class=\"section-break\">* * *</div>\n"
                } else {
                    let cls = pIdx == 0 ? " class=\"first-p\"" : ""
                    bodyHTML += "    <p\(cls)>\(trimmed.xmlEscaped())</p>\n"
                }
            }

            let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en">
            <head>
                <meta charset="utf-8"/>
                <title>\(sanitizedTitle.xmlEscaped())</title>
                <link rel="stylesheet" type="text/css" href="../css/style.css"/>
            </head>
            <body>
            \(bodyHTML)
            </body>
            </html>
            """
            try xhtml.write(to: textDir.appendingPathComponent(htmlName), atomically: true, encoding: .utf8)

            manifestItems.append("<item id=\"\(chapterID)\" href=\"text/\(htmlName)\" media-type=\"application/xhtml+xml\"/>")
            spineItems.append("<itemref idref=\"\(chapterID)\"/>")

            tocEntries.append(
                EPUBManifestBuilder.EPUBTOCEntry(
                    title: sanitizedTitle,
                    href: "text/\(htmlName)",
                    playOrder: idx + 1
                )
            )
        }

        let firstHref = "text/chapter_001.xhtml"
        let bookUUID = UUID().uuidString
        let safeAuthor = (author?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Author"

        let navContent = EPUBManifestBuilder.buildNavContent(firstPageHref: firstHref, tocEntries: tocEntries)
        try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)

        let ncxContent = EPUBManifestBuilder.buildNCXContent(bookUUID: bookUUID, baseFilename: title, firstPageHref: firstHref, tocEntries: tocEntries)
        try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

        let modified = ISO8601DateFormatter().string(from: Date())
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="BookID">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="BookID">urn:uuid:\(bookUUID)</dc:identifier>
                <dc:title>\(title.xmlEscaped())</dc:title>
                <dc:creator>\(safeAuthor.xmlEscaped())</dc:creator>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">\(modified)</meta>
            </metadata>
            <manifest>
                \(manifestItems.joined(separator: "\n        "))
            </manifest>
            <spine toc="ncx">
                \(spineItems.joined(separator: "\n        "))
            </spine>
            <guide>
                <reference type="toc" title="Table of Contents" href="nav.xhtml#toc"/>
                <reference type="text" title="Text" href="\(firstHref)"/>
            </guide>
        </package>
        """
        try opf.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        try EPUBManifestBuilder.containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let cleanTitle = sanitize(title).isEmpty ? "Manuscript" : sanitize(title)
        let outputZipURL = tempDir.appendingPathComponent("\(cleanTitle).epub")

        let archive = try Archive(url: outputZipURL, accessMode: .create, pathEncoding: .utf8)
        let mimetypePath = epubDir.appendingPathComponent("mimetype")
        try "application/epub+zip".write(to: mimetypePath, atomically: true, encoding: .ascii)
        try archive.addEntry(with: "mimetype", fileURL: mimetypePath, compressionMethod: .none)
        try archive.addEntry(with: "META-INF/container.xml", fileURL: metaInfDir.appendingPathComponent("container.xml"), compressionMethod: .none)

        let enumerator = fm.enumerator(at: oebpsDir, includingPropertiesForKeys: [.isDirectoryKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            let res = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if res.isDirectory == true { continue }
            let rel = fileURL.path.replacingOccurrences(of: epubDir.path + "/", with: "")
            try archive.addEntry(with: rel, fileURL: fileURL, compressionMethod: .deflate)
        }

        return outputZipURL
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

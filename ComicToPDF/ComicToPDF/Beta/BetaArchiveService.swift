import Foundation
import ZIPFoundation
import Unrar
import PDFKit
import UIKit

public actor BetaArchiveService {
    public static let shared = BetaArchiveService()
    
    private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "bmp"]
    
    private init() {}
    
    /// Unpacks a comic (CBZ, CBR, PDF) into a unique folder in the temp directory.
    /// Returns the working directory URL and the sorted list of image URLs.
    public func extractComic(from sourceURL: URL) async throws -> (workingDir: URL, imageURLs: [URL]) {
        let ext = sourceURL.pathExtension.lowercased()
        
        if ["cbr", "rar"].contains(ext) {
            return try await extractCBR(from: sourceURL)
        } else if ext == "pdf" {
            return try await extractPDF(from: sourceURL)
        } else {
            // Default to CBZ/ZIP
            return try await extractCBZ(from: sourceURL)
        }
    }
    
    /// Extracts a cover thumbnail as JPEG data for any content type without unzipping the whole archive.
    public func extractCover(from sourceURL: URL, contentType: BetaContentType) async -> Data? {
        let secured = sourceURL.startAccessingSecurityScopedResource()
        defer { if secured { sourceURL.stopAccessingSecurityScopedResource() } }
        
        switch contentType {
        case .pdf:
            return PDFRenderer.renderFirstPage(from: sourceURL, quality: 0.7)
            
        case .epub:
            return await extractEPUBCover(from: sourceURL)
            
        case .comic:
            // CBZ cover extraction: Stream only the first matching image entry
            guard let archive = try? Archive(url: sourceURL, accessMode: .read) else { return nil }
            
            // Find first image entry sorted alphabetically by path
            let imageEntries = archive.filter { entry in
                let filename = (entry.path as NSString).lastPathComponent
                let ext = (filename as NSString).pathExtension.lowercased()
                return self.imageExtensions.contains(ext) &&
                       !entry.path.contains("__MACOSX") &&
                       !filename.hasPrefix("._")
            }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            
            guard let firstEntry = imageEntries.first else { return nil }
            
            var data = Data()
            _ = try? archive.extract(firstEntry) { chunk in
                data.append(chunk)
            }
            return data
            
        case .manga:
            // CBR cover extraction: open archive and get first image
            guard let archive = try? Unrar.Archive(fileURL: sourceURL),
                  let entries = try? archive.entries() else { return nil }
                  
            let imageEntries = entries.filter { entry in
                let filename = (entry.fileName as NSString).lastPathComponent
                let ext = (filename as NSString).pathExtension.lowercased()
                return self.imageExtensions.contains(ext) &&
                       !entry.directory &&
                       !entry.fileName.contains("__MACOSX") &&
                       !filename.hasPrefix("._")
            }.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
            
            guard let firstEntry = imageEntries.first else { return nil }
            return try? archive.extract(firstEntry)
        }
    }
    
    // MARK: - Private Extraction Helpers
    
    private func extractCBZ(from url: URL) async throws -> (workingDir: URL, imageURLs: [URL]) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        
        let fileManager = FileManager.default
        let stem = url.deletingPathExtension().lastPathComponent
        let uniqueID = UUID().uuidString.prefix(6)
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("beta_cbz_\(stem)_\(uniqueID)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        guard let archive = try? Archive(url: url, accessMode: .read) else {
            throw NSError(domain: "BetaArchiveService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open CBZ archive."])
        }
        
        var qualifiedPaths: [String] = []
        for entry in archive {
            let path = entry.path
            let filename = (path as NSString).lastPathComponent
            guard !path.contains("__MACOSX"),
                  !filename.hasPrefix("._"),
                  filename != ".DS_Store",
                  !path.hasSuffix("/") else { continue }
            let ext = (filename as NSString).pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                qualifiedPaths.append(path)
            }
        }
        
        guard !qualifiedPaths.isEmpty else {
            throw NSError(domain: "BetaArchiveService", code: 2, userInfo: [NSLocalizedDescriptionKey: "No images found in CBZ."])
        }
        
        // Sort files to preserve reading order
        qualifiedPaths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        
        var extractedFiles: [URL] = []
        
        // Extract serially to prevent archive read race conditions (ZIPFoundation.Archive is not thread-safe for reads)
        for path in qualifiedPaths {
            guard let entry = archive[path] else { continue }
            let destURL = tempDir.appendingPathComponent((path as NSString).lastPathComponent)
            _ = try archive.extract(entry, to: destURL)
            extractedFiles.append(destURL)
        }
        
        return (tempDir, extractedFiles)
    }
    
    private func extractCBR(from url: URL) async throws -> (workingDir: URL, imageURLs: [URL]) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        
        let fileManager = FileManager.default
        let stem = url.deletingPathExtension().lastPathComponent
        let uniqueID = UUID().uuidString.prefix(6)
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("beta_cbr_\(stem)_\(uniqueID)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        guard let archive = try? Unrar.Archive(fileURL: url) else {
            throw NSError(domain: "BetaArchiveService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to open CBR archive."])
        }
        
        let entries = try archive.entries()
        var extractedFiles: [URL] = []
        
        for entry in entries {
            let filename = (entry.fileName as NSString).lastPathComponent
            guard !entry.directory,
                  !entry.fileName.contains("__MACOSX"),
                  !filename.hasPrefix("._"),
                  filename != ".DS_Store" else { continue }
            
            let ext = (filename as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            
            let destURL = tempDir.appendingPathComponent(filename)
            let data = try archive.extract(entry)
            try data.write(to: destURL, options: .atomic)
            extractedFiles.append(destURL)
        }
        
        guard !extractedFiles.isEmpty else {
            throw NSError(domain: "BetaArchiveService", code: 4, userInfo: [NSLocalizedDescriptionKey: "No images found in CBR."])
        }
        
        // Sort files to preserve reading order
        extractedFiles.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        
        return (tempDir, extractedFiles)
    }
    
    private func extractPDF(from url: URL) async throws -> (workingDir: URL, imageURLs: [URL]) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        
        let fileManager = FileManager.default
        let stem = url.deletingPathExtension().lastPathComponent
        let uniqueID = UUID().uuidString.prefix(6)
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("beta_pdf_\(stem)_\(uniqueID)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let extractedFiles = try PDFRenderer.renderPages(from: url, to: tempDir)
        
        guard !extractedFiles.isEmpty else {
            throw NSError(domain: "BetaArchiveService", code: 6, userInfo: [NSLocalizedDescriptionKey: "No pages rendered from PDF."])
        }
        
        return (tempDir, extractedFiles)
    }
    
    // MARK: - EPUB Cover Extraction
    
    private func extractEPUBCover(from url: URL) async -> Data? {
        guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
        
        // 1. Parse META-INF/container.xml
        guard let containerEntry = archive["META-INF/container.xml"] else { return nil }
        var containerData = Data()
        _ = try? archive.extract(containerEntry) { chunk in containerData.append(chunk) }
        
        guard let opfPath = parseOPFPath(from: containerData) else { return nil }
        
        // 2. Parse OPF file
        guard let opfEntry = archive[opfPath] else { return nil }
        var opfData = Data()
        _ = try? archive.extract(opfEntry) { chunk in opfData.append(chunk) }
        
        let opfDir = (opfPath as NSString).deletingLastPathComponent
        guard let coverHref = parseCoverHref(from: opfData, opfDir: opfDir) else { return nil }
        
        // 3. Extract cover entry
        let fullCoverPath = opfDir.isEmpty ? coverHref : "\(opfDir)/\(coverHref)"
        var targetEntry = archive[fullCoverPath]
        if targetEntry == nil {
            let lowerCoverPath = coverHref.lowercased()
            for e in archive {
                if e.path.lowercased().hasSuffix(lowerCoverPath) {
                    targetEntry = e
                    break
                }
            }
        }
        
        guard let entry = targetEntry else { return nil }
        var coverData = Data()
        _ = try? archive.extract(entry) { chunk in coverData.append(chunk) }
        return coverData
    }
    
    private func parseOPFPath(from data: Data) -> String? {
        let parser = SimpleXMLParser(data: data)
        parser.parse()
        return parser.foundOPFPath
    }
    
    private func parseCoverHref(from data: Data, opfDir: String) -> String? {
        let parser = SimpleXMLParser(data: data)
        parser.parse()
        
        if let coverId = parser.coverMetaValue {
            return parser.manifestItems[coverId]
        }
        
        // Fallback: look for item with id "cover" or "cover-image"
        if let href = parser.manifestItems["cover"] ?? parser.manifestItems["cover-image"] {
            return href
        }
        
        // Fallback 2: look for first image in manifest with "cover" in name
        for (id, href) in parser.manifestItems {
            if id.lowercased().contains("cover") || href.lowercased().contains("cover") {
                let ext = (href as NSString).pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "webp"].contains(ext) {
                    return href
                }
            }
        }
        
        return nil
    }
}

// MARK: - SAX-based SimpleXMLParser for EPUB metadata
private class SimpleXMLParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    
    var foundOPFPath: String?
    var coverMetaValue: String?
    var manifestItems: [String: String] = [:] // id: href
    
    init(data: Data) {
        self.parser = XMLParser(data: data)
        super.init()
        self.parser.delegate = self
    }
    
    func parse() {
        parser.parse()
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        let lower = localName.lowercased()
        
        if lower == "rootfile", let fullPath = attributes["full-path"] {
            foundOPFPath = fullPath
        } else if lower == "meta", attributes["name"] == "cover", let content = attributes["content"] {
            coverMetaValue = content
        } else if lower == "item", let id = attributes["id"], let href = attributes["href"] {
            manifestItems[id] = href
        }
    }
}

// MARK: - Private PDF rendering helper to avoid strict concurrency warnings with non-Sendable PDFKit classes
private struct PDFRenderer {
    static func renderPages(from url: URL, to tempDir: URL) throws -> [URL] {
        guard let document = PDFDocument(url: url) else {
            throw NSError(domain: "BetaArchiveService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to open PDF document."])
        }
        
        var extractedFiles: [URL] = []
        let pageCount = document.pageCount
        
        for i in 0..<pageCount {
            try autoreleasepool {
                guard let page = document.page(at: i) else { return }
                let fileURL = tempDir.appendingPathComponent(String(format: "%04d.jpg", i))
                if let data = renderPage(page, quality: 0.9) {
                    try data.write(to: fileURL)
                    extractedFiles.append(fileURL)
                }
            }
        }
        return extractedFiles
    }
    
    static func renderPage(_ page: PDFPage, quality: CGFloat) -> Data? {
        let pageRect = page.bounds(for: .mediaBox)
        let renderer = UIGraphicsImageRenderer(size: pageRect.size)
        let image = renderer.image { ctx in
            UIColor.white.set()
            ctx.fill(pageRect)
            ctx.cgContext.translateBy(x: 0.0, y: pageRect.size.height)
            ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
        return image.jpegData(compressionQuality: quality)
    }
    
    static func renderFirstPage(from url: URL, quality: CGFloat) -> Data? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0) else { return nil }
        return renderPage(page, quality: quality)
    }
}

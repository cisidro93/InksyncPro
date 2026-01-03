import Foundation
import UIKit
import ZIPFoundation

// ============================================================================
// MARK: - EPUB MERGER
// ============================================================================

class EPUBMerger {
    
    /// Merges multiple EPUB files into a single EPUB.
    /// - Parameters:
    ///   - sourceURLs: List of EPUB URLs to merge.
    ///   - outputURL: Destination URL for the merged EPUB.
    ///   - metadata: Metadata for the new EPUB.
    ///   - settings: Settings for EPUB generation.
    /// - Returns: The URL of the merged EPUB and the total page count.
    static func mergeEPUBs(sourceURLs: [URL], outputURL: URL, metadata: PDFMetadata, settings: EPUBSettings) async throws -> (URL, Int) {
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBMerge_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        var allImages: [URL] = []
        
        // 1. Extract Images from all EPUBs in Reading Order
        for (index, url) in sourceURLs.enumerated() {
            let workingDir = tempDir.appendingPathComponent("source_\(index)")
            try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
            
            // Unzip
            try FileManager.default.unzipItem(at: url, to: workingDir)
            
            // Extract Ordered Images
            let images = try extractOrderedImages(from: workingDir)
            allImages.append(contentsOf: images)
        }
        
        // 2. Generate New EPUB
        let generator = EPUBGenerator(settings: settings, metadata: metadata, compressionQuality: 1.0) // 1.0 to avoid re-compression if not needed
        
        // We use "passthrough: true" logic implicitly in generateEPUB if we pass URLs.
        // However, EPUBGenerator.generateEPUB(from imageURLs:...) logic attempts to compress if needed.
        // We should ensure we don't degrade quality of already compressed images.
        // The generator's logic: if isJPEG and quality >= 1.0, it copies.
        
        // We need a custom name for the file, but we are passing outputURL to this function...
        // Actually EPUBGenerator returns a temp URL. We need to move it.
        
        let outputName = outputURL.deletingPathExtension().lastPathComponent
        let (tempEPUB, pageCount) = try await generator.generateEPUB(from: allImages, outputName: outputName, passthrough: true)
        
        // Move to final destination
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: tempEPUB, to: outputURL)
        
        return (outputURL, pageCount)
    }
    
    // MARK: - Extraction Logic
    
    private static func extractOrderedImages(from rootURL: URL) throws -> [URL] {
        // 1. Find OEBPS/content.opf
        // Look for META-INF/container.xml first
        let containerURL = rootURL.appendingPathComponent("META-INF/container.xml")
        
        var opfPath = "OEBPS/content.opf" // Default
        
        if FileManager.default.fileExists(atPath: containerURL.path),
           let data = try? Data(contentsOf: containerURL),
           let content = String(data: data, encoding: .utf8) {
            // Simple regex to find full-path
            let pattern = "full-path=\"([^\"]+)\""
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) {
                if let range = Range(match.range(at: 1), in: content) {
                    opfPath = String(content[range])
                }
            }
        }
        
        let opfURL = rootURL.appendingPathComponent(opfPath)
        guard FileManager.default.fileExists(atPath: opfURL.path) else {
            // Fallback: just search for images recursively if OPF structure fails
            return try getAllImagesRecursively(from: rootURL)
        }
        
        // 2. Parse OPF to get Manifest and Spine
        let opfParser = OPFParser(url: opfURL)
        guard let spineBase = opfParser.parse() else {
             return try getAllImagesRecursively(from: rootURL)
        }
        
        // 3. Walk Spine to get XHTMLs -> Images
        var orderedImages: [URL] = []
        let opfDir = opfURL.deletingLastPathComponent()
        
        for itemRef in spineBase.spine {
            if let href = spineBase.manifest[itemRef] {
                let xhtmlURL = opfDir.appendingPathComponent(href)
                let imagesInPage = try extractImagesFromXHTML(at: xhtmlURL)
                orderedImages.append(contentsOf: imagesInPage)
            }
        }
        
        if orderedImages.isEmpty {
             return try getAllImagesRecursively(from: rootURL)
        }
        
        return orderedImages
    }
    
    private static func extractImagesFromXHTML(at url: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url) else { return [] }
        
        // Regex for <img src="...">
        let pattern = "<img[^>]+src=\"([^\"]+)\""
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        
        var images: [URL] = []
        let baseDir = url.deletingLastPathComponent()
        
        for match in matches {
            if let range = Range(match.range(at: 1), in: content) {
                let src = String(content[range])
                // Handle relative paths
                let imageURL = baseDir.appendingPathComponent(src).standardized
                if FileManager.default.fileExists(atPath: imageURL.path) {
                    images.append(imageURL)
                }
            }
        }
        
        return images
    }
    
    private static func getAllImagesRecursively(from url: URL) throws -> [URL] {
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp"]
        var images: [URL] = []
        
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            while let fileURL = enumerator.nextObject() as? URL {
                if imageExtensions.contains(fileURL.pathExtension.lowercased()) {
                    // Ignore thumbnails or cover if they duplicate others? No, keep all for now.
                    // Filter out some system files
                    if !fileURL.lastPathComponent.hasPrefix(".") {
                        images.append(fileURL)
                    }
                }
            }
        }
        return images.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Mini OPF Parser

class OPFParser: NSObject, XMLParserDelegate {
    let url: URL
    var manifest: [String: String] = [:] // id -> href
    var spine: [String] = [] // idrefs
    
    private var inManifest = false
    private var inSpine = false
    
    init(url: URL) {
        self.url = url
        super.init()
    }
    
    func parse() -> (manifest: [String: String], spine: [String])? {
        guard let parser = XMLParser(contentsOf: url) else { return nil }
        parser.delegate = self
        if parser.parse() {
            return (manifest, spine)
        }
        return nil
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "manifest" { inManifest = true }
        if elementName == "spine" { inSpine = true }
        
        if inManifest && elementName == "item" {
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = href
            }
        }
        
        if inSpine && elementName == "itemref" {
            if let idref = attributeDict["idref"] {
                spine.append(idref)
            }
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "manifest" { inManifest = false }
        if elementName == "spine" { inSpine = false }
    }
}

// ============================================
// FILE: ComicToPDF/Services/EPUBMerger.swift
// ============================================
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
    ///   - precomputedManifest: Optional panel manifest if manual editing was performed.
    /// - Returns: The URL of the merged EPUB and the total page count.
    static func mergeEPUBs(sourceURLs: [URL], outputURL: URL, metadata: PDFMetadata, settings: EPUBSettings, precomputedManifest: EPUBPanelManifest? = nil, onStatusUpdate: ((String) -> Void)? = nil) async throws -> (URL, Int) {
        
        print("🔄 Starting EPUB merge for \(sourceURLs.count) files")
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBMerge_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Create EPUB structure
        let epubDir = tempDir.appendingPathComponent("epub")
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let textDir = oebpsDir.appendingPathComponent("text")
        
        for dir in [epubDir, metaInfDir, oebpsDir, imagesDir, textDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        
        // Write mimetype
        try "application/epub+zip".write(to: epubDir.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        
        // Write container.xml
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        // Write CSS
        let cssContent = """
        @charset "UTF-8";
        * { margin: 0; padding: 0; border: 0; }
        html, body { 
            width: 100%; height: 100%; 
            margin: 0; padding: 0; 
            background-color: #000;
            overflow: hidden;
        }
        .page { 
            width: 100vw; height: 100vh; 
            display: flex; 
            align-items: center; 
            justify-content: center;
            overflow: hidden;
            background-color: #000;
        }
        img { 
            width: 100%; height: 100%; 
            object-fit: cover;
            object-position: center;
        }
        @media (orientation: portrait) {
            img {
                width: 100%; height: auto;
                max-height: 100vh;
                object-fit: contain;
            }
        }
        @media (orientation: landscape) {
            img {
                width: auto; height: 100%;
                max-width: 100vw;
                object-fit: contain;
            }
        }
        """
        try cssContent.write(to: oebpsDir.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        
        // ---------------------------------------------------------
        // PANEL VIEW: GENERATE METADATA
        // ---------------------------------------------------------
        var panelManifest: EPUBPanelManifest? = precomputedManifest

        if settings.enablePanelView && panelManifest == nil {
            print("🎯 Generating panel view metadata...")
            
            // Load all images for panel detection
            var pageImages: [UIImage] = []
            
            for url in sourceURLs {
                let tempExtract = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PanelExtract_\(UUID().uuidString)")
                
                try FileManager.default.createDirectory(at: tempExtract, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempExtract) }
                
                try FileManager.default.unzipItem(at: url, to: tempExtract)
                
                // Find images in this EPUB
                let searchPaths = [
                    tempExtract.appendingPathComponent("OEBPS/images"),
                    tempExtract.appendingPathComponent("OPS/images"),
                    tempExtract.appendingPathComponent("images"),
                    tempExtract
                ]
                
                for searchPath in searchPaths {
                    if let files = try? FileManager.default.contentsOfDirectory(at: searchPath, includingPropertiesForKeys: nil) {
                        let imageFiles = files
                            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
                            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                        
                        for imageFile in imageFiles {
                            if let data = try? Data(contentsOf: imageFile),
                               let image = UIImage(data: data) {
                                pageImages.append(image)
                            }
                        }
                    }
                }
            }
            
            // Detect panels
            if !pageImages.isEmpty {
                // Check if we already have a manifest (from manual review)
                // If so, SKIP this entire block
                if settings.enablePanelView && panelManifest == nil {
                    
                    let detectionMode: PanelExtractor.ExtractionMode
                switch settings.panelDetectionMode {
                case .automatic:
                    detectionMode = .automatic
                case .grid2x2:
                    detectionMode = .grid(rows: 2, columns: 2)
                case .grid3x3:
                    detectionMode = .grid(rows: 3, columns: 3)
                case .grid2x3:
                    detectionMode = .grid(rows: 2, columns: 3)
                }
                
                panelManifest = try await PanelExtractor.extractPanelsFromImages(
                    pageImages,
                    mode: detectionMode,
                    settings: settings,
                    onStatusUpdate: onStatusUpdate // ✅ Pass it here
                )
                
                print("✅ Panel metadata generated for \(pageImages.count) pages")
                
                // Save JSON manifest
                if let manifest = panelManifest {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let manifestData = try encoder.encode(manifest)
                    let manifestPath = oebpsDir.appendingPathComponent("panel-manifest.json")
                    try manifestData.write(to: manifestPath)
                }
            } // End if settings.enablePanelView && panelManifest == nil
            } // End if !pageImages.isEmpty
        }
        
        var pageNumber = 1
        var manifestItems: [String] = []
        var spineItems: [String] = []
        
        // Process each source EPUB
        for (index, sourceURL) in sourceURLs.enumerated() {
            print("📖 Processing EPUB \(index + 1)/\(sourceURLs.count): \(sourceURL.lastPathComponent)")
            
            let workingDir = tempDir.appendingPathComponent("source_\(index)")
            try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
            
            // Unzip
            try FileManager.default.unzipItem(at: sourceURL, to: workingDir)
            print("   ✓ Unzipped to \(workingDir.path)")
            
            // Try multiple possible image directory locations
            var sourceImagesDir: URL? = nil
            let possiblePaths = [
                "OEBPS/images",
                "OPS/images", 
                "EPUB/images",
                "images",
                "."
            ]
            
            for path in possiblePaths {
                let dir = workingDir.appendingPathComponent(path)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue {
                    // Check if folder has images
                    if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                        let hasImages = files.contains { ["jpg", "jpeg", "png", "gif", "webp"].contains($0.pathExtension.lowercased()) }
                        if hasImages {
                            sourceImagesDir = dir
                            print("   ✓ Found images in: \(path)")
                            break
                        }
                    }
                }
            }
            
            if sourceImagesDir == nil {
                print("   ⚠️ checking root for images...")
                // Fallback check root
                if let files = try? FileManager.default.contentsOfDirectory(at: workingDir, includingPropertiesForKeys: nil) {
                    let hasImages = files.contains { ["jpg", "jpeg", "png", "gif", "webp"].contains($0.pathExtension.lowercased()) }
                    if hasImages {
                        sourceImagesDir = workingDir
                    }
                }
            }
            
            guard let imagesDirURL = sourceImagesDir else {
                print("   ⚠️ WARNING: No images directory found in EPUB")
                continue
            }
            
            // Get all image files
            let imageFiles = try FileManager.default.contentsOfDirectory(
                at: imagesDirURL,
                includingPropertiesForKeys: nil
            )
            .filter { url in
                let ext = url.pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "gif", "webp", "bmp"].contains(ext)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            
            print("   ✓ Found \(imageFiles.count) images")
            
            if imageFiles.isEmpty {
                print("   ⚠️ WARNING: Images directory exists but contains no images")
                continue
            }
            
            // Copy each image
            for (imgIndex, imageURL) in imageFiles.enumerated() {
                let ext = imageURL.pathExtension
                let destImageName = "page\(pageNumber).\(ext)"
                let destImageURL = imagesDir.appendingPathComponent(destImageName)
                
                // DIRECT COPY - NO PROCESSING
                do {
                    try FileManager.default.copyItem(at: imageURL, to: destImageURL)
                    
                    // Verify file was copied
                    let attrs = try FileManager.default.attributesOfItem(atPath: destImageURL.path)
                    let size = attrs[.size] as? Int64 ?? 0
                    
                    if imgIndex == 0 || imgIndex == imageFiles.count - 1 {
                        print("      Page \(pageNumber): \(destImageName) (\(size) bytes)")
                    }
                } catch {
                    print("   ❌ ERROR copying \(imageURL.lastPathComponent): \(error)")
                    throw error
                }
                
                // Media type
                let mediaType: String
                switch ext.lowercased() {
                case "png": mediaType = "image/png"
                case "gif": mediaType = "image/gif"
                case "webp": mediaType = "image/webp"
                default: mediaType = "image/jpeg"
                }
                
                // Manifest
                manifestItems.append("""
                    <item id="image\(pageNumber)" href="images/\(destImageName)" media-type="\(mediaType)"/>
                """)
                
                // Panel Data Attributes
                var panelDataAttributes = ""
                if let manifest = panelManifest,
                   let pagePanels = manifest.pages.first(where: { $0.pageNumber == pageNumber }) {
                    
                    let panelJSON = try JSONEncoder().encode(pagePanels.panels)
                    if let panelString = String(data: panelJSON, encoding: .utf8) {
                        panelDataAttributes = " data-panels='\(panelString.replacingOccurrences(of: "'", with: "&apos;"))'"
                    }
                }

                // XHTML
                let xhtmlFileName = "page\(pageNumber).xhtml"
                let xhtmlContent = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE html>
                <html xmlns="http://www.w3.org/1999/xhtml">
                <head>
                    <title>Page \(pageNumber)</title>
                    <link rel="stylesheet" type="text/css" href="../style.css"/>
                    <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
                </head>
                <body>
                    <div class="page"\(panelDataAttributes)>
                        <img src="../images/\(destImageName)" alt="Page \(pageNumber)"/>
                    </div>
                </body>
                </html>
                """
                try xhtmlContent.write(to: textDir.appendingPathComponent(xhtmlFileName), atomically: true, encoding: .utf8)
                
                manifestItems.append("""
                    <item id="page\(pageNumber)" href="text/\(xhtmlFileName)" media-type="application/xhtml+xml"/>
                """)
                
                spineItems.append("<itemref idref=\"page\(pageNumber)\"/>")
                
                pageNumber += 1
            }
            
            try? FileManager.default.removeItem(at: workingDir)
        }
        
        let totalPages = pageNumber - 1
        print("📊 Total pages merged: \(totalPages)")
        
        if totalPages == 0 {
            throw NSError(domain: "EPUBMerger", code: 500,
                      userInfo: [NSLocalizedDescriptionKey: "No images were found in any EPUB files"])
        }

        // CREATE COVER IMAGE FOR KINDLE THUMBNAIL
        if totalPages > 0 {
            // Find the first page image (could be jpg, jpeg, or png)
            var coverCreated = false
            let possibleExts = ["jpg", "jpeg", "png", "webp"]
            
            for ext in possibleExts {
                let firstPageURL = imagesDir.appendingPathComponent("page1.\(ext)")
                if FileManager.default.fileExists(atPath: firstPageURL.path) {
                    let coverURL = imagesDir.appendingPathComponent("cover.jpg")
                    try FileManager.default.copyItem(at: firstPageURL, to: coverURL)
                    print("📖 Created cover.jpg from page1.\(ext) for Kindle thumbnail")
                    coverCreated = true
                    break
                }
            }
            
            if !coverCreated {
                print("⚠️ Warning: Could not create cover image")
            }
        }
        
        // FIX: Removed metadata.isbn as it does not exist. Using UUID instead.
        let bookID = "urn:uuid:\(UUID().uuidString)"
        let bookTitle = metadata.title.isEmpty ? "Comic" : metadata.title
        let bookAuthor = metadata.author.isEmpty ? "Unknown" : metadata.author
        
        // Build panel metadata tags
        var panelMetadata = "        <meta property=\"rendition:layout\">pre-paginated</meta>\n        <meta property=\"rendition:spread\">none</meta>\n"
        if panelManifest != nil {
            panelMetadata += "        <meta name=\"RegionMagnification\" content=\"true\"/>\n        <meta name=\"comic-panel-view\" content=\"enabled\"/>\n"
        }

        let contentOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>\(bookTitle)</dc:title>
                <dc:identifier id="BookID">\(bookID)</dc:identifier>
                <dc:creator>\(bookAuthor)</dc:creator>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta>
                <meta name="cover" content="cover-image"/>
        \(panelMetadata)
            </metadata>
            <manifest>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="css" href="style.css" media-type="text/css"/>
                <item id="cover-image" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
        \(manifestItems.joined(separator: "\n"))
            </manifest>
            <spine toc="ncx">
        \(spineItems.joined(separator: "\n"))
            </spine>
            <guide>
                <reference type="cover" title="Cover" href="text/page1.xhtml"/>
            </guide>
        </package>
        """
        try contentOPF.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: String.Encoding.utf8)
        
        // Create toc.ncx
        let pageCount = totalPages
        let tocNCX = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head>
                <meta name="dtb:uid" content="\(bookID)"/>
                <meta name="dtb:depth" content="1"/>
                <meta name="dtb:totalPageCount" content="\(pageCount)"/>
                <meta name="dtb:maxPageNumber" content="\(pageCount)"/>
            </head>
            <docTitle>
                <text>\(bookTitle)</text>
            </docTitle>
            <navMap>
                <navPoint id="navPoint-1" playOrder="1">
                    <navLabel><text>Start</text></navLabel>
                    <content src="page1.xhtml"/>
                </navPoint>
            </navMap>
        </ncx>
        """
        try tocNCX.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: String.Encoding.utf8)
        
        // Create archive
        print("📦 Creating EPUB archive...")
        let finalEPUB = tempDir.appendingPathComponent("\(bookTitle).epub")
        
        // FIX: Handle Archive optional return. In some ZIPFoundation versions, init is failable (init?) and non-throwing.
        // We use guard let to unwrap it safely.
        // FIX: Use throwing init for Archive
        let archive = try Archive(url: finalEPUB, accessMode: .create, preferredEncoding: .utf8)
        
        // Add mimetype first (uncompressed)
        try archive.addEntry(with: "mimetype", relativeTo: epubDir, compressionMethod: .none)
        
        // Add all other files
        let allFiles = try FileManager.default.subpathsOfDirectory(atPath: epubDir.path)
        for file in allFiles where file != "mimetype" {
            try archive.addEntry(with: file, relativeTo: epubDir, compressionMethod: .deflate)
        }
        
        // Check final file size
        let finalAttrs = try FileManager.default.attributesOfItem(atPath: finalEPUB.path)
        let finalSize = finalAttrs[.size] as? Int64 ?? 0
        print("✅ EPUB created: \(ByteCountFormatter.string(fromByteCount: finalSize, countStyle: .file))")
        
        // Move to destination
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: finalEPUB, to: outputURL)
        
        print("✅ Merge complete! \(totalPages) pages")
        return (outputURL, totalPages)
    }
}

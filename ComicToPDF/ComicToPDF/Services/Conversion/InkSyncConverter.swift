import SwiftUI
import ZIPFoundation

/// The InkSyncConverter generates a strict standard EPUB utilizing the SVG-Viewport architecture.
/// This approach forces the Amazon KFX ingestion engine (Cloud via Send-to-Kindle) to retain
/// edge-to-edge formatting by encapsulating every image within an SVG coordinate space that
/// inherently maps 1:1 against the viewport, preventing the injection of `.reading-margins`.
/// It additionally uses `PDOC` metadata to bypass "Receipt Validation" / unowned book errors.
class InkSyncConverter {
    
    func convert(sourceURL: URL, settings: ConversionSettings, progress: @escaping (Double) -> Void) async throws -> [URL] {
        Logger.shared.log("Starting SVG-Viewport PDOC Conversion", category: "Converter")
        
        let fileManager = FileManager.default
        
        // Strip ALL extensions to resolve base name
        var baseFilename = sourceURL.lastPathComponent
        while !baseFilename.isEmpty && baseFilename.contains(".") {
            let stripped = (baseFilename as NSString).deletingPathExtension
            if stripped == baseFilename { break }
            baseFilename = stripped
        }
        
        // 1. Safe Extraction
        progress(0.1)
        let extractionResult = try await ZipUtilities.extractComic(from: sourceURL)
        let tempDir = extractionResult.workingDir
        defer { try? fileManager.removeItem(at: tempDir) }
        
        let originalImageURLs = extractionResult.imageURLs
        guard !originalImageURLs.isEmpty else {
            throw NSError(domain: "Converter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No images found"])
        }
        
        // 2. Prepare OEBPS directory structure
        let batchDir = tempDir.appendingPathComponent("EPUB_Export")
        let oebpsDir = batchDir.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let textDir = oebpsDir.appendingPathComponent("text")
        let cssDir = oebpsDir.appendingPathComponent("css")
        let metaInfDir = batchDir.appendingPathComponent("META-INF")
        
        try? fileManager.removeItem(at: batchDir)
        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: textDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cssDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        
        // 3. Setup EPUB standard scaffold
        try "application/epub+zip".write(to: batchDir.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        // Phase 6 KCC-Aligned Fixed-Layout CSS
        let cssContent = """
        @page { margin: 0; padding: 0; }
        html, body { margin: 0; padding: 0; width: 100%; height: 100%; background-color: #000000; overflow: hidden; }
        svg { display: block; margin: 0; padding: 0; width: 100%; height: 100%; }
        """
        try cssContent.write(to: cssDir.appendingPathComponent("comic.css"), atomically: true, encoding: .utf8)
        
        var spineItems: [String] = []
        var manifestItems: [String] = []
        manifestItems.append("<item id=\"css\" href=\"css/comic.css\" media-type=\"text/css\"/>")
        
        // Tracking standard image processing logic
        let totalCount = Double(originalImageURLs.count)
        var globalImageIndex = 0
        var firstBatchCoverData: Data? = nil
        var globalWidth = 1000
        var globalHeight = 1500
        
        // Nav document generation (Mandatory for Kindle EPUB layout even if unused)
        manifestItems.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        let navContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
        <head>
            <meta charset="utf-8" />
            <title>Navigation</title>
        </head>
        <body>
            <nav epub:type="toc" id="toc">
                <h1>Table of Contents</h1>
                <ol>
                    <li><a href="text/chunk_0001.xhtml">Start Reading</a></li>
                </ol>
            </nav>
            <nav epub:type="landmarks">
                <ol>
                    <li><a epub:type="bodymatter" href="text/chunk_0001.xhtml">Start</a></li>
                </ol>
            </nav>
        </body>
        </html>
        """
        try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        
        // 4. Processing Sequence
        for (index, srcURL) in originalImageURLs.enumerated() {
            
            // Image data ingestion & optional enhancement
            var finalData: Data
            let needsCompression = settings.compressionQuality != .high
            let needsProcessing = needsCompression || settings.imageEnhancement.grayscale || settings.imageEnhancement.autoContrast || settings.imageEnhancement.invertColors
            
            if needsProcessing {
                if let processedImage = ImageProcessor.process(imageURL: srcURL, settings: settings) {
                    finalData = processedImage.jpegData(compressionQuality: settings.compressionQuality.value) ?? (try? Data(contentsOf: srcURL)) ?? Data()
                } else {
                    finalData = (try? Data(contentsOf: srcURL)) ?? Data()
                }
            } else {
                finalData = (try? Data(contentsOf: srcURL)) ?? Data()
            }
            
            // Dimensions extraction PER PAGE
            var imgWidth = 1000
            var imgHeight = 1500
            if let image = UIImage(data: finalData) {
                imgWidth = Int(image.size.width)
                imgHeight = Int(image.size.height)
            }
            
            // Capture cover mapping and global dimensions (falling back to first image)
            if index == 0 {
                firstBatchCoverData = finalData
                globalWidth = imgWidth
                globalHeight = imgHeight
            }
            
            globalImageIndex += 1
            let trueExt = (srcURL.pathExtension.lowercased() == "png") ? "png" : "jpg"
            let safeExt = (trueExt == "jpg") ? "jpeg" : trueExt
            let newImageName = String(format: "image_%04d.%@", globalImageIndex, trueExt)
            
            let destURL = imagesDir.appendingPathComponent(newImageName)
            try finalData.write(to: destURL)
            
            // Register Manifest Component
            let propertiesAttr = (index == 0) ? " properties=\"cover-image\"" : ""
            manifestItems.append("<item id=\"img_\(globalImageIndex)\" href=\"images/\(newImageName)\" media-type=\"image/\(safeExt)\"\(propertiesAttr)/>")
            
            // KCC-Aligned True Fixed-Layout SVG Generation
            let chunkXHTML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head>
                <title>Page \(globalImageIndex)</title>
                <meta name="viewport" content="width=\(imgWidth), height=\(imgHeight)"/>
                <link rel="stylesheet" type="text/css" href="../css/comic.css"/>
            </head>
            <body>
                <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 \(imgWidth) \(imgHeight)" width="100%" height="100%">
                    <image width="\(imgWidth)" height="\(imgHeight)" xlink:href="../images/\(newImageName)"/>
                </svg>
            </body>
            </html>
            """
            
            let chunkName = String(format: "chunk_%04d.xhtml", globalImageIndex)
            try chunkXHTML.write(to: textDir.appendingPathComponent(chunkName), atomically: true, encoding: .utf8)
            
            manifestItems.append("<item id=\"chunk_\(globalImageIndex)\" href=\"text/\(chunkName)\" media-type=\"application/xhtml+xml\"/>")
            spineItems.append("<itemref idref=\"chunk_\(globalImageIndex)\"/>")
            
            progress(0.1 + (0.8 * Double(index) / totalCount))
        }
        
        // 5. OPF Generation enforcing PDOC and Absolute Fixed-Layout (but avoiding E013 primary-writing-mode)
        let bookUUID = UUID().uuidString
        let epubName = baseFilename
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="BookID">urn:uuid:\(bookUUID)</dc:identifier>
                <dc:title>\(epubName.xmlEscaped())</dc:title>
                <dc:creator>Inksync Pro</dc:creator>
                <dc:language>en</dc:language>
                
                <!-- KCC-Aligned Fixed Layout Enforcement -->
                <meta name="fixed-layout" content="true"/>
                <meta name="original-resolution" content="\(globalWidth)x\(globalHeight)"/>
                <meta name="book-type" content="comic"/>
                <meta name="primary-writing-mode" content="\(settings.mangaMode ? "horizontal-rl" : "horizontal-lr")"/>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">auto</meta>
                <meta property="rendition:spread">none</meta>
                
                <!-- SVG/PDF Cloud bypass flag -->
                <meta name="comic-panel-view" content="guided"/>
                
                <!-- PDOC override to entirely bypass Receipt Validations upon syncing -->
                <meta name="cdetype" content="PDOC"/>
                <meta name="mobi-cdetype" content="PDOC"/>
                
                <meta name="cover" content="img_1"/>
            </metadata>
            <manifest>
                \(manifestItems.joined(separator: "\n        "))
            </manifest>
            <spine page-progression-direction="\(settings.mangaMode ? "rtl" : "ltr")">
                \(spineItems.joined(separator: "\n        "))
            </spine>
            <guide>
                <reference type="cover" title="Cover" href="text/chunk_0001.xhtml"/>
                <reference type="text" title="Start" href="text/chunk_0001.xhtml"/>
            </guide>
        </package>
        """
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // 6. Manual Zipping to satisfy mimetype constraints
        let safeName = epubName.map { char -> String in
            if char.isLetter || char.isNumber || char == "-" { return String(char) }
            else if char == "_" || char.isWhitespace { return " " }
            else { return "" }
        }.joined()
        
        let outputFilename = (safeName.isEmpty ? "comic" : safeName) + ".epub"
        let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(outputFilename)
        if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }
        
        do {
            guard let archive = try? Archive(url: outputURL, accessMode: .create, pathEncoding: .utf8) else {
                throw NSError(domain: "Converter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create EPUB archive"])
            }
            
            // Mimetype uncompressed & 1st entry
            let mimetypePath = batchDir.appendingPathComponent("mimetype")
            try archive.addEntry(with: "mimetype", fileURL: mimetypePath, compressionMethod: .none)
            
            // Container 2nd entry
            let containerPath = metaInfDir.appendingPathComponent("container.xml")
            try archive.addEntry(with: "META-INF/container.xml", fileURL: containerPath, compressionMethod: .deflate)
            
            let enumerator = fileManager.enumerator(at: oebpsDir, includingPropertiesForKeys: nil)!
            while let fileURL = enumerator.nextObject() as? URL {
                let rV = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
                if rV.isDirectory == true { continue }
                if let relativePath = fileURL.path.components(separatedBy: "\(batchDir.path)/").last {
                    try archive.addEntry(with: relativePath, fileURL: fileURL, compressionMethod: .deflate)
                }
            }
        } catch {
            throw error
        }
        
        Logger.shared.log("SVG-Viewport Generation Complete: \(outputURL.lastPathComponent)", category: "Converter")
        progress(1.0)
        return [outputURL]
    }
}

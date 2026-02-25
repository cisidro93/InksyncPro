import SwiftUI
import ZIPFoundation

/// KF8AZW3Converter — Precision Kindle Fixed-Layout Engine
///
/// Produces a KF8-compatible EPUB.
/// This is the format used by all major Kindle comic tools (KCC, KindleComicCreator)
/// for sideloading via USB or Local Wi-Fi.
///
/// Coordinate Guarantee (1:1 Pixel Parity):
///   Panel coordinates in the output HTML exactly match the source CBZ pixel coordinates.
///   A panel at (100, 200) in CBZ pixel space appears at top:200px, left:100px in the Kindle magnifier.
///   No AI refinement or auto-cropping is applied to the passed-in panel coordinates.
class KF8AZW3Converter {

    // MARK: - Public Interface (mirrors CBZToEPUBConverter.convert)

    func convert(
        sourceURL: URL,
        settings: ConversionSettings,
        manualManifest: [Int: [PanelExtractor.Panel]]?,
        progress: @escaping (Double) -> Void
    ) async throws -> [URL] {
        Logger.shared.log("KF8AZW3Converter: Starting. Manual panels: \(manualManifest?.count ?? 0) pages", category: "KF8")

        let fileManager = FileManager.default

        // Strip all extensions from filename
        var baseFilename = sourceURL.lastPathComponent
        while !baseFilename.isEmpty && baseFilename.contains(".") {
            let stripped = (baseFilename as NSString).deletingPathExtension
            if stripped == baseFilename { break }
            baseFilename = stripped
        }

        // 1. Extract archive
        progress(0.05)
        let extractionResult = try await ZipUtilities.extractComic(from: sourceURL)
        let tempDir = extractionResult.workingDir
        defer { try? fileManager.removeItem(at: tempDir) }

        let originalImageURLs = extractionResult.imageURLs
        guard !originalImageURLs.isEmpty else {
            throw NSError(domain: "KF8Converter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No images found in archive"])
        }

        // 2. Process images into batches (respect split mode)
        progress(0.1)
        var batches: [[(url: URL, index: Int, data: Data)]] = []
        var currentBatch: [(url: URL, index: Int, data: Data)] = []
        var currentBatchSize: Int64 = 0
        let limit = settings.splitMode.limit
        let totalCount = Double(originalImageURLs.count)

        for (index, srcURL) in originalImageURLs.enumerated() {
            let finalData = try loadImageData(srcURL: srcURL, settings: settings)
            let itemSize = Int64(finalData.count)

            let isNoLimit = limit == Int64.max
            let overheadBuffer: Int64 = 500 * 1024
            let exceedsLimit = (currentBatchSize + itemSize + overheadBuffer) > limit

            if !isNoLimit && exceedsLimit && !currentBatch.isEmpty {
                batches.append(currentBatch)
                currentBatch = []
                currentBatchSize = 0
            }

            currentBatch.append((url: srcURL, index: index, data: finalData))
            currentBatchSize += itemSize
            progress(0.1 + (0.35 * Double(index) / totalCount))
        }
        if !currentBatch.isEmpty { batches.append(currentBatch) }

        // 3. Generate output per batch
        var generatedFiles: [URL] = []
        var contentSize = CGSize(width: 1080, height: 1920)
        var hasCapturedResolution = false
        var firstBatchCoverData: Data?

        for (batchIndex, batch) in batches.enumerated() {
            let partSuffix = batches.count > 1 ? " (pt \(batchIndex + 1))" : ""
            let baseName = baseFilename + partSuffix

            // Build directory structure
            let batchDir    = tempDir.appendingPathComponent("AZW3_Part_\(batchIndex)")
            let oebpsDir    = batchDir.appendingPathComponent("OEBPS")
            let imagesDir   = oebpsDir.appendingPathComponent("images")
            let textDir     = oebpsDir.appendingPathComponent("text")
            let cssDir      = oebpsDir.appendingPathComponent("css")
            let metaInfDir  = batchDir.appendingPathComponent("META-INF")

            try? fileManager.removeItem(at: batchDir)
            try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: textDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: cssDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)

            // mimetype (MUST be first, uncompressed)
            try "application/epub+zip".write(to: batchDir.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)

            // META-INF/container.xml
            let containerXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                <rootfiles>
                    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                </rootfiles>
            </container>
            """
            try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

            // CSS — identical to CBZToEPUBConverter for visual parity
            let cssContent = """
            * { margin: 0; padding: 0; border: 0; }
            html, body {
                width: 100%;
                height: 100%;
                overflow: hidden;
                background-color: #000000;
            }
            .page {
                position: absolute;
                width: 100%;
                height: 100%;
                margin: 0;
                padding: 0;
            }
            .page-image {
                position: absolute;
                top: 0;
                left: 0;
                width: 100%;
                height: 100%;
            }
            /* Kindle Panel View Overlays */
            a.app-amzn-magnify {
                display: block;
                position: absolute;
                z-index: 10;
                text-decoration: none;
                background: transparent;
            }
            .panel-source {
                position: absolute;
                width: 100%;
                height: 100%;
                background: transparent;
            }
            .panel-target {
                position: absolute;
                z-index: 5;
                pointer-events: none;
                background: transparent;
            }
            """
            try cssContent.write(to: cssDir.appendingPathComponent("comic.css"), atomically: true, encoding: .utf8)

            // Capture resolution from first image in batch
            if let firstItem = batch.first, let image = UIImage(data: firstItem.data) {
                contentSize = image.size
                hasCapturedResolution = true
                if batchIndex == 0 { firstBatchCoverData = firstItem.data }
            }

            let widthPx  = Int(contentSize.width)
            let heightPx = Int(contentSize.height)
            let bookUUID = UUID().uuidString
            let isPortrait = heightPx > widthPx
            let orientation = isPortrait ? "portrait" : "landscape"
            let writingMode = settings.mangaMode ? "horizontal-rl" : "horizontal-lr"

            var spineItems: [String] = []
            var manifestItems: [String] = []

            manifestItems.append("<item id=\"css\" href=\"css/comic.css\" media-type=\"text/css\"/>")
            manifestItems.append("<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>")
            manifestItems.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")

            // nav.xhtml
            let navContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
            <head><title>Navigation</title><meta charset="utf-8" /></head>
            <body>
                <nav epub:type="toc" id="toc">
                    <h1>Table of Contents</h1>
                    <ol><li><a href="text/page_0001.xhtml">Start Reading</a></li></ol>
                </nav>
            </body>
            </html>
            """
            try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)

            // toc.ncx
            let ncxContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
                <head><meta name="dtb:uid" content="urn:uuid:\(bookUUID)"/></head>
                <docTitle><text>\(baseName)</text></docTitle>
                <navMap>
                    <navPoint id="navPoint-1" playOrder="1">
                        <navLabel><text>Start</text></navLabel>
                        <content src="text/page_0001.xhtml"/>
                    </navPoint>
                </navMap>
            </ncx>
            """
            try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

            // Process pages
            var batchPanels: [Int: [PanelExtractor.Panel]] = [:]
            for (localIndex, item) in batch.enumerated() {
                let trueExt  = (item.url.pathExtension.lowercased() == "png") ? "png" : "jpg"
                let safeExt  = (trueExt == "jpg") ? "jpeg" : trueExt
                let imageName = String(format: "image_%04d.%@", localIndex + 1, trueExt)

                try item.data.write(to: imagesDir.appendingPathComponent(imageName))

                if !hasCapturedResolution {
                    if let image = UIImage(data: item.data) {
                        contentSize = image.size
                        hasCapturedResolution = true
                        if batchIndex == 0 && localIndex == 0 { firstBatchCoverData = item.data }
                    }
                }

                // Retrieve panels for this page from the manifest
                // Panels are in Vision space (0–1, bottom-left origin).
                // CBZToEPUBConverter.generateXHTML handles the Y-flip to top-left origin,
                // preserving 1:1 pixel correspondence with the source CBZ coordinates.
                let pagePanels = manualManifest?[item.index] ?? []
                if !pagePanels.isEmpty {
                    batchPanels[localIndex] = pagePanels
                }

                let imageW = Int(UIImage(data: item.data)?.size.width  ?? contentSize.width)
                let imageH = Int(UIImage(data: item.data)?.size.height ?? contentSize.height)
                let globalPageNum = item.index + 1

                // Reuse the proven XHTML generator from CBZToEPUBConverter
                let xhtmlContent = CBZToEPUBConverter.generateXHTML(
                    imageName: imageName,
                    title: "Page \(globalPageNum)",
                    width: imageW,
                    height: imageH,
                    panels: pagePanels,
                    pageIndex: globalPageNum
                )
                let xhtmlName = String(format: "page_%04d.xhtml", globalPageNum)
                try xhtmlContent.write(to: textDir.appendingPathComponent(xhtmlName), atomically: true, encoding: .utf8)

                // Cover retention for split volumes
                if batchIndex > 0 && localIndex == 0, let coverData = firstBatchCoverData {
                    let coverImgName = "cover_reused.jpg"
                    try? coverData.write(to: imagesDir.appendingPathComponent(coverImgName))
                    let cvW = Int(contentSize.width); let cvH = Int(contentSize.height)
                    let coverXHTML = CBZToEPUBConverter.generateXHTML(imageName: coverImgName, title: "Cover", width: cvW, height: cvH, panels: [], pageIndex: 0)
                    try? coverXHTML.write(to: textDir.appendingPathComponent("cover_reused.xhtml"), atomically: true, encoding: .utf8)
                    manifestItems.append("<item id=\"cover_reused_img\" href=\"images/\(coverImgName)\" media-type=\"image/jpeg\" properties=\"cover-image\"/>")
                    manifestItems.append("<item id=\"cover_reused_page\" href=\"text/cover_reused.xhtml\" media-type=\"application/xhtml+xml\"/>")
                    spineItems.append("<itemref idref=\"cover_reused_page\" properties=\"page-spread-center\"/>")
                }

                let coverProp = (localIndex == 0 && batchIndex == 0) ? "properties=\"cover-image\"" : ""
                manifestItems.append("<item id=\"img_\(localIndex+1)\" href=\"images/\(imageName)\" media-type=\"image/\(safeExt)\" \(coverProp)/>")
                manifestItems.append("<item id=\"page_\(localIndex+1)\" href=\"text/\(xhtmlName)\" media-type=\"application/xhtml+xml\"/>")

                // No spread properties in Pro Panel mode — linear single-page flow
                spineItems.append("<itemref idref=\"page_\(localIndex+1)\"/>")
            }

            // KF8-specific OPF metadata
            // region-all-mag-adp: enables Kindle's adaptive region magnification
            // EBOK cover guide entry: required for cover/lock-screen display on Kindle hardware
            
            // ✅ Guided View (ComicInfo/panels.json equivalence)
            var comicInfoMeta = ""
            if !batchPanels.isEmpty {
                var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ComicInfo>\n  <Pages>\n"
                let sortedKeys = batchPanels.keys.sorted()
                for key in sortedKeys {
                    if let panels = batchPanels[key] {
                        xml += "    <Page Image=\"\(key)\">\n"
                        for panel in panels {
                            xml += "      <Panel x=\"\(panel.boundingBox.minX)\" y=\"\(panel.boundingBox.minY)\" width=\"\(panel.boundingBox.width)\" height=\"\(panel.boundingBox.height)\" />\n"
                        }
                        xml += "    </Page>\n"
                    }
                }
                xml += "  </Pages>\n</ComicInfo>"
                
                if let data = xml.data(using: .utf8) {
                    let base64 = data.base64EncodedString()
                    comicInfoMeta = "\n                    <meta name=\"inksync-comicinfo\" content=\"\(base64)\"/>"
                }
            }

            let kf8Metadata = """
                    <meta property="rendition:layout">pre-paginated</meta>
                    <meta property="rendition:orientation">\(orientation)</meta>
                    <meta property="rendition:spread">landscape</meta>
                    <meta name="fixed-layout" content="true"/>
                    <meta name="RegionMagnification" content="true"/>
                    <meta name="region-all-mag-adp" content="1"/>
                    <meta name="original-resolution" content="\(widthPx)x\(heightPx)"/>
                    <meta name="book-type" content="comic"/>
                    <meta name="primary-writing-mode" content="\(writingMode)"/>
                    <meta name="zero-gutter" content="true"/>
                    <meta name="zero-margin" content="true"/>
                    <meta name="ke-border-color" content="#FFFFFF"/>
                    <meta name="ke-border-width" content="0"/>
                    <meta name="orientation-lock" content="\(orientation)"/>
                    <meta name="cover" content="img_1"/>\(comicInfoMeta)
            """

            let opfContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:epub="http://www.idpf.org/2007/ops" unique-identifier="BookID" version="3.0" prefix="rendition: http://www.idpf.org/vocab/rendition/# dcterms: http://purl.org/dc/terms/">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:identifier id="BookID">urn:uuid:\(bookUUID)</dc:identifier>
                    <dc:title>\(baseName.xmlEscaped())</dc:title>
                    <dc:language>en</dc:language>
                    <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta>
                    \(kf8Metadata)
                </metadata>
                <manifest>
                    \(manifestItems.joined(separator: "\n        "))
                </manifest>
                <spine toc="ncx" page-progression-direction="\(settings.mangaMode ? "rtl" : "ltr")">
                    \(spineItems.joined(separator: "\n        "))
                </spine>
                <guide>
                    <reference type="cover" title="Cover" href="text/page_0001.xhtml"/>
                </guide>
            </package>
            """

            try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

            // Package as .epub (KF8 EPUB)
            let safeName = baseFilename.map { char -> String in
                if char.isLetter || char.isNumber || char == "-" { return String(char) }
                if char == "_" || char.isWhitespace { return " " }
                return ""
            }.joined()

            let outputFilename = (safeName.isEmpty ? "comic" : safeName) + partSuffix + ".epub"
            let outputURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(outputFilename)
            if fileManager.fileExists(atPath: outputURL.path) { try fileManager.removeItem(at: outputURL) }

            // Manual ZIP: mimetype must be STORED (uncompressed) and FIRST
            try {
                guard let archive = Archive(url: outputURL, accessMode: .create) else {
                    throw NSError(domain: "KF8Converter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create .epub archive"])
                }

                let mimetypePath = batchDir.appendingPathComponent("mimetype")
                try archive.addEntry(with: "mimetype", fileURL: mimetypePath, compressionMethod: .none)
                let containerPath = metaInfDir.appendingPathComponent("container.xml")
                try archive.addEntry(with: "META-INF/container.xml", fileURL: containerPath, compressionMethod: .deflate)

                let enumerator = fileManager.enumerator(at: oebpsDir, includingPropertiesForKeys: nil)!
                while let fileURL = enumerator.nextObject() as? URL {
                    let rv = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
                    if rv.isDirectory == true { continue }
                    if let relativePath = fileURL.path.components(separatedBy: "\(batchDir.path)/").last {
                        try archive.addEntry(with: relativePath, fileURL: fileURL, compressionMethod: .deflate)
                    }
                }
            }()

            generatedFiles.append(outputURL)
            Logger.shared.log("KF8AZW3Converter: Created \(outputFilename)", category: "KF8")
            progress(0.45 + (0.55 * Double(batchIndex + 1) / Double(batches.count)))
        }

        progress(1.0)
        return generatedFiles
    }

    // MARK: - Private Helpers

    /// Load and optionally re-encode image data from a CBZ page.
    /// Respects compressionQuality and device optimization settings.
    /// Forces JPEG encoding for WebP/HEIC/AVIF inputs (Kindle only supports JPEG/PNG).
    private func loadImageData(srcURL: URL, settings: ConversionSettings) throws -> Data {
        let ext = srcURL.pathExtension.lowercased()
        let kindleSafeFormats = ["jpg", "jpeg", "png"]

        let needsCompression = settings.compressionQuality != .high
        var targetSize: CGSize? = nil
        if settings.optimizeForDevice {
            targetSize = settings.targetDevice.resolution
        } else if settings.compressionQuality == .compact {
            targetSize = CGSize(width: 1440, height: 1920)
        }

        if needsCompression, let image = UIImage(contentsOfFile: srcURL.path) {
            let resized = resizeImage(image, targetSize: targetSize)
            return resized.jpegData(compressionQuality: settings.compressionQuality.value)
                ?? (try? Data(contentsOf: srcURL))
                ?? Data()
        }

        if kindleSafeFormats.contains(ext) {
            return (try? Data(contentsOf: srcURL)) ?? Data()
        }

        // Unsafe format — force JPEG
        if let image = UIImage(contentsOfFile: srcURL.path),
           let jpegData = image.jpegData(compressionQuality: 0.9) {
            return jpegData
        }
        return (try? Data(contentsOf: srcURL)) ?? Data()
    }

    private func resizeImage(_ image: UIImage, targetSize: CGSize?) -> UIImage {
        guard let target = targetSize else { return image }
        let w = image.cgImage?.width ?? Int(image.size.width)
        let h = image.cgImage?.height ?? Int(image.size.height)
        let current = CGSize(width: w, height: h)
        if current.width <= target.width && current.height <= target.height { return image }
        let scale = min(target.width / current.width, target.height / current.height)
        let newSize = CGSize(width: current.width * scale, height: current.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

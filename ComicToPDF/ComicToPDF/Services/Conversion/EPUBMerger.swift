import Foundation
import UIKit
import ZIPFoundation

struct EPUBMerger: Sendable {
    
    // Merge multiple EPUBs into a single omnibus EPUB
    func mergeEPUBs(sourceURLs: [URL], outputURL: URL, settings: ConversionSettings, overrideCoverData: Data? = nil, sourceMetadata: PDFMetadata? = nil) async throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        
        // 1. Structure
        let epubDir = tempDir.appendingPathComponent("EPUB_Merge")
        let oebpsDir = epubDir.appendingPathComponent("OEBPS")
        let textDir = oebpsDir.appendingPathComponent("text")
        let imagesDir = oebpsDir.appendingPathComponent("images")
        let cssDir = oebpsDir.appendingPathComponent("css")
        
        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: textDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cssDir, withIntermediateDirectories: true)
        
        // 2. CSS
        try EPUBManifestBuilder.cssContent.write(to: cssDir.appendingPathComponent("comic.css"), atomically: true, encoding: .utf8)
        
        // 1.5 Load active cover data
        var activeCoverData = overrideCoverData
        if activeCoverData == nil, let firstURL = sourceURLs.first {
            let tempExtract = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? fileManager.createDirectory(at: tempExtract, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempExtract) }
            
            try? fileManager.unzipItem(at: firstURL, to: tempExtract)
            if let images = try? findImages(in: tempExtract), let firstImg = images.first {
                activeCoverData = try? Data(contentsOf: firstImg)
            }
        }
        
        // Ensure cover is in sRGB if it's Display P3
        if let coverData = activeCoverData {
            activeCoverData = ImageProcessor.convertToSRGB(data: coverData)
        }
        
        var manifestItems: [String] = []
        var spineItems: [String] = []
        manifestItems.append("<item id=\"css\" href=\"css/comic.css\" media-type=\"text/css\"/>")
        manifestItems.append("<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>")
        manifestItems.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        
        var globalPageIndex = 1
        // When cover is injected into the spine and linked as a spread (page-spread-left/right),
        // the first content page must occupy the alternating slot (page 2) to prevent two consecutive identical spreads.
        var globalPageCounter = (activeCoverData != nil && settings.linkCoverAsSpread) ? 2 : 1
        var hasLandscapeSpreads = false
        
        // 2.5 Inject Override Cover if Present
        if let coverData = activeCoverData {
            let coverFilename = "cover.jpg"
            let destURL = imagesDir.appendingPathComponent(coverFilename)
            try? coverData.write(to: destURL)
            
            // The cover image must carry properties="cover-image" so that the OPF
            // <meta name="cover" content="cover_img"/> is consistent. Kindle's
            // ingestor checks that the item referenced by <meta name="cover"> has this
            // property and fails with E999 if it does not. The duplicate is still
            // suppressed because cover.xhtml (first spine item) wraps the image —
            // auto-injection only fires when a cover-image item has NO spine XHTML wrapper.
            manifestItems.append("<item id=\"cover_img\" href=\"images/\(coverFilename)\" media-type=\"image/jpeg\" properties=\"cover-image\"/>")
            let coverXHTML = EPUBManifestBuilder.buildCoverXHTML(coverFilename: coverFilename, isManga: settings.mangaMode)
            try coverXHTML.write(to: textDir.appendingPathComponent("cover.xhtml"), atomically: true, encoding: .utf8)
            manifestItems.append("<item id=\"cover_page\" href=\"text/cover.xhtml\" media-type=\"application/xhtml+xml\"/>")
            let coverSpreadTag: String
            if settings.linkCoverAsSpread {
                coverSpreadTag = settings.mangaMode ? " properties=\"page-spread-right\"" : " properties=\"page-spread-left\""
            } else {
                coverSpreadTag = ""
            }
            spineItems.append("<itemref idref=\"cover_page\"\(coverSpreadTag)/>")
        }
        
        // 3. Process Each EPUB
        for (index, url) in sourceURLs.enumerated() {
            let unzipDir = tempDir.appendingPathComponent("unzip_\(index)")
            try fileManager.createDirectory(at: unzipDir, withIntermediateDirectories: true)
            try fileManager.unzipItem(at: url, to: unzipDir)
            
            // Extract Images
            let foundImages = try findImages(in: unzipDir)
            
            for (imgIndex, imgURL) in foundImages.enumerated() {
                // Skip the first page of the first EPUB if we are using it as the cover
                if index == 0 && imgIndex == 0 && activeCoverData != nil {
                    continue
                }
                
                try autoreleasepool {
                    let trueExt = (imgURL.pathExtension.lowercased() == "png") ? "png" : "jpg"
                    let safeExt = (trueExt == "jpg") ? "jpeg" : trueExt
                    let newName = String(format: "image_%05d.%@", globalPageIndex, trueExt)
                    let destURL = imagesDir.appendingPathComponent(newName)
                    
                    // Copy and convert WebP to JPEG if needed
                    try copyAndPrepareImage(from: imgURL, to: destURL, settings: settings)
                    
                    // Detect actual image pixel dimensions for 1:1 viewport matching and spread assignment.
                    var imgW = 1980; var imgH = 2640; var isLandscape = false
                    if let src = CGImageSourceCreateWithURL(destURL as CFURL, nil),
                       let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                        var w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 1980
                        var h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 2640
                        if let ori = props[kCGImagePropertyOrientation] as? UInt32, [5,6,7,8].contains(ori) { swap(&w, &h) }
                        imgW = w
                        imgH = h
                        if w > 0 && h > 0 && Double(w) > Double(h) * 1.1 {
                            isLandscape = true; hasLandscapeSpreads = true
                        }
                    }
                    
                    // Manifest & HTML — use actual dimensions so landscape SVG viewport is correct
                    let htmlName = String(format: "page_%05d.xhtml", globalPageIndex)
                    let htmlContent = EPUBManifestBuilder.buildChunkXHTML(
                        chunkIndex: globalPageIndex,
                        images: [newName],
                        title: "Page \(globalPageIndex)",
                        pageWidth: imgW,
                        pageHeight: imgH
                    )
                    try? htmlContent.write(to: textDir.appendingPathComponent(htmlName), atomically: true, encoding: .utf8)
                    
                    let isFirstPageCover = (globalPageIndex == 1 && activeCoverData == nil)
                    // The cover image (img_1) must carry properties="cover-image" so that the
                    // OPF <meta name="cover" content="img_1"/> is consistent — Kindle's ingestor
                    // checks that the item referenced by <meta name="cover"> has this property and
                    // fails with E999 if it does not.
                    let coverImageProp = isFirstPageCover ? " properties=\"cover-image\"" : ""
                    manifestItems.append("<item id=\"page_\(globalPageIndex)\" href=\"text/\(htmlName)\" media-type=\"application/xhtml+xml\"/>")
                    manifestItems.append("<item id=\"img_\(globalPageIndex)\" href=\"images/\(newName)\" media-type=\"image/\(safeExt)\"\(coverImageProp)/>")
                    
                    // Landscape images span the full display — omit spread properties so Kindle
                    // renders them full-bleed without trying to pair them with an adjacent page.
                    let spreadTag: String
                    if isLandscape {
                        spreadTag = ""
                    } else if settings.linkCoverAsSpread {
                        if settings.mangaMode {
                            spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-right\"" : " properties=\"page-spread-left\""
                        } else {
                            spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-left\"" : " properties=\"page-spread-right\""
                        }
                    } else {
                        if globalPageCounter == 1 {
                            spreadTag = "" // Cover stands alone centered
                        } else if settings.mangaMode {
                            spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-left\"" : " properties=\"page-spread-right\""
                        } else {
                            spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-right\"" : " properties=\"page-spread-left\""
                        }
                    }
                    spineItems.append("<itemref idref=\"page_\(globalPageIndex)\"\(spreadTag)/>")
                    
                    globalPageIndex += 1
                    // Only advance the spread counter for portrait pages. Landscape pages
                    // are centered and must not disturb the left/right pairing sequence.
                    if !isLandscape { globalPageCounter += 1 }
                }
            }
        }
        
        let firstPageHref = (activeCoverData != nil) ? "text/cover.xhtml" : "text/page_00001.xhtml"
        
        // 4. Metadata (OPF)
        let opfTitle = sourceMetadata?.series ?? sourceMetadata?.title ?? "Merged Comic Collection"
        let bookUUID = UUID().uuidString
        let coverMeta: String? = (activeCoverData != nil) ? "cover_img" : "img_1"
        
        let opfContent = EPUBManifestBuilder.buildOPFContent(
            bookUUID: bookUUID,
            baseFilename: opfTitle,
            coverMetaID: coverMeta,
            manifestItems: manifestItems,
            spineItems: spineItems,
            isManga: settings.mangaMode,
            firstPageHref: firstPageHref,
            hasLandscapeSpreads: hasLandscapeSpreads,
            author: sourceMetadata?.writer ?? sourceMetadata?.author
        )
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // 5. Nav
        let navContent = EPUBManifestBuilder.buildNavContent(firstPageHref: firstPageHref, isManga: settings.mangaMode)
        try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        
        // 5.5 NCX
        let ncxContent = EPUBManifestBuilder.buildNCXContent(bookUUID: bookUUID, baseFilename: opfTitle, firstPageHref: firstPageHref)
        try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
        
        // 6. Zip
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try EPUBManifestBuilder.containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        
        let archive = try Archive(url: outputURL, accessMode: .create, pathEncoding: .utf8)
        
        // 7. Critical: Inject IDPF Valid Uncompressed Mimetype File
        let mimetypePath = epubDir.appendingPathComponent("mimetype")
        try "application/epub+zip".write(to: mimetypePath, atomically: true, encoding: .ascii)
        try archive.addEntry(with: "mimetype", fileURL: mimetypePath, compressionMethod: .none)
        
        // Inject container.xml second, matching CBZToEPUBConverter
        let containerPath = epubDir.appendingPathComponent("META-INF/container.xml")
        try archive.addEntry(with: "META-INF/container.xml", fileURL: containerPath, compressionMethod: .none)
        
        // 8. Recursive Payload Addition of OEBPS folder contents
        let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey]
        let stdOEBPS = oebpsDir.standardizedFileURL.path
        if let enumerator = fileManager.enumerator(at: oebpsDir.standardizedFileURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            while let fileURL = enumerator.nextObject() as? URL {
                try autoreleasepool {
                    let stdFile = fileURL.standardizedFileURL
                    var isDirectory: ObjCBool = false
                    fileManager.fileExists(atPath: stdFile.path, isDirectory: &isDirectory)
                    if isDirectory.boolValue { return }
                    
                    let filePath = stdFile.path
                    guard filePath.hasPrefix(stdOEBPS) else { return }
                    let subPath = String(filePath.dropFirst(stdOEBPS.count))
                    let relativePath = "OEBPS" + (subPath.hasPrefix("/") ? subPath : "/" + subPath)
                    
                    try archive.addEntry(with: relativePath, fileURL: stdFile, compressionMethod: .deflate)
                }
            }
        }
    }
    
    // MARK: - Smart Omnibus Parsing
    func mergeWithSmartSplit(sourceURLs: [URL], baseOutputName: String, targetDir: URL, settings: ConversionSettings, overrideCoverData: Data? = nil, progressCallback: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        let diagMetrics = ConversionDiagnosticLogger.logStart(
            jobTitle: "EPUB Convert & Merge (\(baseOutputName))",
            settings: settings,
            sourceFiles: sourceURLs
        )
        let fileManager = FileManager.default
        var outputFiles: [URL] = []
        var currentVolumeIndex = 1
        let thresholdBytes: Int = settings.omnibusSplitThresholdMB == 99999 ? .max : settings.omnibusSplitThresholdMB * 1024 * 1024
        var currentBundleBytes = 0
        
        // 1.5 Load active cover data
        var activeCoverData = overrideCoverData
        if activeCoverData == nil, let firstURL = sourceURLs.first {
            let tempExtract = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? fileManager.createDirectory(at: tempExtract, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempExtract) }
            
            try? fileManager.unzipItem(at: firstURL, to: tempExtract)
            if let images = try? findImages(in: tempExtract), let firstImg = images.first {
                activeCoverData = try? Data(contentsOf: firstImg)
            }
        }
        
        // Ensure cover is in sRGB if it's Display P3
        if let coverData = activeCoverData {
            activeCoverData = ImageProcessor.convertToSRGB(data: coverData)
        }
        
        // Setup initial Working Dir
        var currentEpubDir = try initializeBlankEPUBDir(volumeOffset: currentVolumeIndex)
        var globalPageIndex = 1
        // Content pages always start at counter 1. The cover's spread position is set
        // independently via coverSpreadTag — it does not consume a globalPageCounter slot.
        var globalPageCounter = 1
        var hasLandscapeSpreads = false
        var manifestItems: [String] = []
        manifestItems.append("<item id=\"css\" href=\"css/comic.css\" media-type=\"text/css\"/>")
        manifestItems.append("<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>")
        manifestItems.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        var spineItems: [String] = []
        
        // Base closure to "Seal" a volume
        let sealCurrentEPUB = { [self] (dirURL: URL, volIdx: Int, mItems: [String], sItems: [String], volumeHasLandscape: Bool) throws -> URL in
            let oebps = dirURL.appendingPathComponent("OEBPS")
            
            let bookUUID = UUID().uuidString
            let coverMeta: String? = (activeCoverData != nil) ? "cover_img" : "img_1"
            let firstPageHref = (activeCoverData != nil) ? "text/cover.xhtml" : "text/page_00001.xhtml"
            let opfTitle = "\(baseOutputName) (Vol \(volIdx))"
            
            let opf = EPUBManifestBuilder.buildOPFContent(
                bookUUID: bookUUID,
                baseFilename: opfTitle,
                coverMetaID: coverMeta,
                manifestItems: mItems,
                spineItems: sItems,
                isManga: settings.mangaMode,
                firstPageHref: firstPageHref,
                hasLandscapeSpreads: volumeHasLandscape,
                author: nil
            )
            try opf.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
            
            let navContent = EPUBManifestBuilder.buildNavContent(firstPageHref: firstPageHref, isManga: settings.mangaMode)
            try navContent.write(to: oebps.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
            
            let ncxContent = EPUBManifestBuilder.buildNCXContent(bookUUID: bookUUID, baseFilename: opfTitle, firstPageHref: firstPageHref)
            try ncxContent.write(to: oebps.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
            
            let vTitle = "\(baseOutputName) - Part \(volIdx).epub"
            let finalURL = targetDir.appendingPathComponent(vTitle)
            
            if fileManager.fileExists(atPath: finalURL.path) { try fileManager.removeItem(at: finalURL) }
            let archive = try Archive(url: finalURL, accessMode: .create, pathEncoding: .utf8)
            
            let mimetypePath = dirURL.appendingPathComponent("mimetype")
            try "application/epub+zip".write(to: mimetypePath, atomically: true, encoding: .ascii)
            try archive.addEntry(with: "mimetype", fileURL: mimetypePath, compressionMethod: .none)
            
            let containerPath = dirURL.appendingPathComponent("META-INF/container.xml")
            try archive.addEntry(with: "META-INF/container.xml", fileURL: containerPath, compressionMethod: .none)
            
            let oebpsDir = dirURL.appendingPathComponent("OEBPS")
            let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey]
            let stdOEBPS = oebpsDir.standardizedFileURL.path
            if let enumerator = fileManager.enumerator(at: oebpsDir.standardizedFileURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                while let fileURL = enumerator.nextObject() as? URL {
                    try autoreleasepool {
                        let stdFile = fileURL.standardizedFileURL
                        var isDirectory: ObjCBool = false
                        fileManager.fileExists(atPath: stdFile.path, isDirectory: &isDirectory)
                        if isDirectory.boolValue { return }
                        
                        let filePath = stdFile.path
                        guard filePath.hasPrefix(stdOEBPS) else { return }
                        let subPath = String(filePath.dropFirst(stdOEBPS.count))
                        let relativePath = "OEBPS" + (subPath.hasPrefix("/") ? subPath : "/" + subPath)
                        try archive.addEntry(with: relativePath, fileURL: stdFile, compressionMethod: .deflate)
                    }
                }
            }
            try? fileManager.removeItem(at: dirURL)
            return finalURL
        }
        
        let injectCover = { (targetImagesDir: URL, targetOESPSDir: URL, partNumber: Int, destManifest: inout [String], destSpine: inout [String]) throws -> Int in
            if let baseCover = activeCoverData {
                let badgedData = self.createBadgedCover(from: baseCover, partNumber: partNumber, placement: settings.omnibusBadgePlacement) ?? baseCover
                
                let coverFilename = "cover.jpg"
                try badgedData.write(to: targetImagesDir.appendingPathComponent(coverFilename))
                
                destManifest.append("<item id=\"cover_img\" href=\"images/\(coverFilename)\" media-type=\"image/jpeg\" properties=\"cover-image\"/>")
                // Write cover.xhtml so the cover-image manifest item is referenced from the spine.
                // Kindle Cloud auto-injects a duplicate cover page for any cover-image item that
                // is NOT in the spine — this cover.xhtml prevents that auto-injection.
                let coverXHTML = EPUBManifestBuilder.buildCoverXHTML(coverFilename: coverFilename, isManga: settings.mangaMode)
                let textDir = targetOESPSDir.appendingPathComponent("text")
                try coverXHTML.write(to: textDir.appendingPathComponent("cover.xhtml"), atomically: true, encoding: .utf8)
                destManifest.append("<item id=\"cover_page\" href=\"text/cover.xhtml\" media-type=\"application/xhtml+xml\"/>")
                let coverSpreadTag: String
                if settings.linkCoverAsSpread {
                    coverSpreadTag = settings.mangaMode ? " properties=\"page-spread-right\"" : " properties=\"page-spread-left\""
                } else {
                    coverSpreadTag = ""
                }
                destSpine.append("<itemref idref=\"cover_page\"\(coverSpreadTag)/>")
                return 0 // cover.xhtml is the first spine entry; regular pages follow at globalPageIndex 1+
            }
            return 0
        }
        
        globalPageIndex += try injectCover(currentEpubDir.appendingPathComponent("OEBPS/images"), currentEpubDir.appendingPathComponent("OEBPS"), currentVolumeIndex, &manifestItems, &spineItems)
        
        let totalFiles = sourceURLs.count
        
        for (idx, sourceBox) in sourceURLs.enumerated() {
            let scratchDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fileManager.createDirectory(at: scratchDir, withIntermediateDirectories: true)
            try fileManager.unzipItem(at: sourceBox, to: scratchDir)
            
            let images = try findImages(in: scratchDir)
            let issueMB: Int = images.reduce(0) { sum, imgURL in
                let imgAttrs = try? fileManager.attributesOfItem(atPath: imgURL.path)
                let bytes: Int = (imgAttrs?[.size] as? Int) ?? 0
                return sum + bytes
            }
            
            if currentBundleBytes + issueMB > thresholdBytes && currentBundleBytes > 0 {
                let builtEPUBURL = try sealCurrentEPUB(currentEpubDir, currentVolumeIndex, manifestItems, spineItems, hasLandscapeSpreads)
                outputFiles.append(builtEPUBURL)
                
                currentVolumeIndex += 1
                currentBundleBytes = 0
                globalPageIndex = 1
                globalPageCounter = (activeCoverData != nil && settings.linkCoverAsSpread) ? 2 : 1
                hasLandscapeSpreads = false
                currentEpubDir = try initializeBlankEPUBDir(volumeOffset: currentVolumeIndex)
                manifestItems = []
                manifestItems.append("<item id=\"css\" href=\"css/comic.css\" media-type=\"text/css\"/>")
                manifestItems.append("<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>")
                manifestItems.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
                spineItems = []
                
                globalPageIndex += try injectCover(currentEpubDir.appendingPathComponent("OEBPS/images"), currentEpubDir.appendingPathComponent("OEBPS"), currentVolumeIndex, &manifestItems, &spineItems)
            }
            
            let activeOEBPS = currentEpubDir.appendingPathComponent("OEBPS")
            let activeImages = activeOEBPS.appendingPathComponent("images")
            let activeText = activeOEBPS.appendingPathComponent("text")
            
            for (imgIdx, img) in images.enumerated() {
                try autoreleasepool {
                    // Skip the first image of the first EPUB if cover override is active (Part 1 cover page)
                    if idx == 0 && imgIdx == 0 && activeCoverData != nil {
                        return
                    }
                    
                    let trueExt = (img.pathExtension.lowercased() == "png") ? "png" : "jpg"
                    let safeExt = (trueExt == "jpg") ? "jpeg" : trueExt
                    let newName = String(format: "image_%05d.%@", globalPageIndex, trueExt)
                    let destURL = activeImages.appendingPathComponent(newName)
                    try copyAndPrepareImage(from: img, to: destURL, settings: settings)
                    
                    // Detect actual image pixel dimensions for 1:1 viewport matching and spread assignment.
                    var imgW = 1980; var imgH = 2640; var isLandscape = false
                    if let src = CGImageSourceCreateWithURL(destURL as CFURL, nil),
                       let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                        var w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 1980
                        var h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 2640
                        if let ori = props[kCGImagePropertyOrientation] as? UInt32, [5,6,7,8].contains(ori) { swap(&w, &h) }
                        imgW = w
                        imgH = h
                        if w > 0 && h > 0 && Double(w) > Double(h) * 1.1 {
                            isLandscape = true; hasLandscapeSpreads = true
                        }
                    }
                    
                    let htmlName = String(format: "page_%05d.xhtml", globalPageIndex)
                    let htmlContent = EPUBManifestBuilder.buildChunkXHTML(
                        chunkIndex: globalPageIndex,
                        images: [newName],
                        title: "Page \(globalPageIndex)",
                        pageWidth: imgW,
                        pageHeight: imgH
                    )
                    try? htmlContent.write(to: activeText.appendingPathComponent(htmlName), atomically: true, encoding: .utf8)
                    
                    let isFirstPageCover = (globalPageIndex == 1 && activeCoverData == nil)
                    // The cover image (img_1) must carry properties="cover-image" so that the
                    // OPF <meta name="cover" content="img_1"/> is consistent — Kindle's ingestor
                    // checks that the item referenced by <meta name="cover"> has this property and
                    // fails with E999 if it does not. The duplicate-cover problem is suppressed by
                    // page_1.xhtml being the FIRST spine item wrapping img_1.
                    let coverImageProp = isFirstPageCover ? " properties=\"cover-image\"" : ""
                    manifestItems.append("<item id=\"page_\(globalPageIndex)\" href=\"text/\(htmlName)\" media-type=\"application/xhtml+xml\"/>")
                    manifestItems.append("<item id=\"img_\(globalPageIndex)\" href=\"images/\(newName)\" media-type=\"image/\(safeExt)\"\(coverImageProp)/>")
                    
                    // Landscape images span the full display — omit spread properties so Kindle
                    // renders them full-bleed without trying to pair them with an adjacent page.
                    let spreadTag: String
                    if isLandscape {
                        spreadTag = ""
                    } else if settings.linkCoverAsSpread {
                        if settings.mangaMode {
                            spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-right\"" : " properties=\"page-spread-left\""
                        } else {
                            spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-left\"" : " properties=\"page-spread-right\""
                        }
                    } else {
                        if globalPageCounter == 1 {
                            spreadTag = "" // Cover stands alone centered
                        } else if settings.mangaMode {
                            spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-left\"" : " properties=\"page-spread-right\""
                        } else {
                            spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-right\"" : " properties=\"page-spread-left\""
                        }
                    }
                    spineItems.append("<itemref idref=\"page_\(globalPageIndex)\"\(spreadTag)/>")
                    
                    globalPageIndex += 1
                    // Only advance the spread counter for portrait pages. Landscape pages
                    // are centered and must not disturb the left/right pairing sequence.
                    if !isLandscape { globalPageCounter += 1 }
                }
            }
            
            currentBundleBytes += issueMB
            try? fileManager.removeItem(at: scratchDir)
            progressCallback(Double(idx + 1) / Double(totalFiles))
        }
        
        if currentBundleBytes > 0 {
            let builtEPUBURL = try sealCurrentEPUB(currentEpubDir, currentVolumeIndex, manifestItems, spineItems, hasLandscapeSpreads)
            outputFiles.append(builtEPUBURL)
        }
        
        for file in outputFiles {
            ConversionDiagnosticLogger.logCompletion(metrics: diagMetrics, outputURL: file)
        }
        
        progressCallback(1.0)
        return outputFiles
    }
    
    // Engine Component: Creates strict EPUB hierarchy boilerplate
    private func initializeBlankEPUBDir(volumeOffset: Int) throws -> URL {
        let fileManager = FileManager.default
        let newDir = fileManager.temporaryDirectory.appendingPathComponent("Omnibus_V\(volumeOffset)_\(UUID().uuidString)")
        let oebpsDir = newDir.appendingPathComponent("OEBPS")
        try fileManager.createDirectory(at: oebpsDir.appendingPathComponent("images"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: oebpsDir.appendingPathComponent("text"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: oebpsDir.appendingPathComponent("css"), withIntermediateDirectories: true)
        let cssContent = EPUBManifestBuilder.cssContent
        try cssContent.write(to: oebpsDir.appendingPathComponent("css/comic.css"), atomically: true, encoding: .utf8)
        try fileManager.createDirectory(at: newDir.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try EPUBManifestBuilder.containerXML.write(to: newDir.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        return newDir
    }
    
    private func createBadgedCover(from originalData: Data, partNumber: Int, placement: CoverBadgePlacement) -> Data? {
        guard placement != .hidden, let uiImage = UIImage(data: originalData) else { return originalData }
        if partNumber <= 1 { return originalData } // Only badge Part 2+
        
        let size = uiImage.size
        // 🚨 ENFORCE sRGB Color Space. Wide-color (P3) JPEGs will hard-brick Kindle E-Ink screens.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.preferredRange = .standard // Forces sRGB instead of device-dependent P3
        
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let finalImage = renderer.image { ctx in
            uiImage.draw(at: .zero)
            
            let text = "PART \(partNumber)"
            let fontSize = max(size.width * 0.05, 40)
            let font = UIFont.systemFont(ofSize: fontSize, weight: .black)
            
            let strokeTextAttributes: [NSAttributedString.Key: Any] = [
                .strokeColor: UIColor.black,
                .foregroundColor: UIColor.white,
                .strokeWidth: -6.0,
                .font: font
            ]
            
            let attrStr = NSAttributedString(string: text, attributes: strokeTextAttributes)
            let textSize = attrStr.size()
            
            let badgePadding: CGFloat = 16
            let boxWidth = textSize.width + (badgePadding * 2)
            let boxHeight = textSize.height + (badgePadding * 2)
            let offset: CGFloat = size.width * 0.03
            
            var boxOrigin = CGPoint.zero
            switch placement {
            case .topLeft: boxOrigin = CGPoint(x: offset, y: offset)
            case .topRight: boxOrigin = CGPoint(x: size.width - boxWidth - offset, y: offset)
            case .bottomLeft: boxOrigin = CGPoint(x: offset, y: size.height - boxHeight - offset)
            case .bottomRight: boxOrigin = CGPoint(x: size.width - boxWidth - offset, y: size.height - boxHeight - offset)
            case .center: boxOrigin = CGPoint(x: (size.width - boxWidth)/2, y: (size.height - boxHeight)/2)
            case .hidden: return
            }
            
            let rect = CGRect(origin: boxOrigin, size: CGSize(width: boxWidth, height: boxHeight))
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 10)
            
            let cgCtx = ctx.cgContext
            cgCtx.saveGState()
            cgCtx.setShadow(offset: CGSize(width: 4, height: 4), blur: 8, color: UIColor.black.withAlphaComponent(0.6).cgColor)
            UIColor.systemRed.setFill()
            path.fill()
            cgCtx.restoreGState()
            
            let textOrigin = CGPoint(x: boxOrigin.x + badgePadding, y: boxOrigin.y + badgePadding)
            attrStr.draw(at: textOrigin)
        }
        
        return finalImage.jpegData(compressionQuality: 0.9)
    }

    private func copyAndPrepareImage(from srcURL: URL, to destURL: URL, settings: ConversionSettings) throws {
        // Validate that the image file is decodable as a UIImage
        guard let originalImage = UIImage(contentsOfFile: srcURL.path) else {
            throw NSError(domain: "ImageProcessor", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Invalid or corrupted image file '\(srcURL.lastPathComponent)' in source archive. Please verify your source file."
            ])
        }
        
        let ext = srcURL.pathExtension.lowercased()
        let isUltraLossless = settings.compressionQuality == .ultra
        
        // Always run image through the processing pipeline (downscaling, sRGB color conversion, contrast)
        let processedImage = ImageProcessor.process(image: originalImage, settings: settings) ?? originalImage
        
        let quality = isUltraLossless ? 1.0 : settings.compressionQuality.value
        let data: Data?
        if ext == "png" && isUltraLossless {
            data = processedImage.pngData()
        } else {
            // Encode as standard Baseline sRGB JPEG for 100% Kindle compatibility
            data = processedImage.jpegData(compressionQuality: quality)
        }
        
        guard let finalData = data, !finalData.isEmpty else {
            throw NSError(domain: "ImageProcessor", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode Kindle-compliant JPEG data for '\(srcURL.lastPathComponent)'."
            ])
        }
        
        try finalData.write(to: destURL)
    }

    private func findImages(in directory: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var images: [URL] = []
        let validExts = ["jpg", "jpeg", "png", "webp"]
        for case let fileURL as URL in enumerator {
            if validExts.contains(fileURL.pathExtension.lowercased()) {
                images.append(fileURL)
            }
        }
        return images.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}


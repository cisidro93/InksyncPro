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
        let cssContent = """
        @page { margin: 0; padding: 0; }
        html, body { margin: 0; padding: 0; width: 100%; height: 100%; background-color: #000000; }
        .chunk-container { width: 100%; height: 100%; margin: 0; padding: 0; }
        .page { width: 100%; height: 100%; margin: 0; padding: 0; }
        .page-image { display: block; width: 100%; height: 100%; }
        """
        try cssContent.write(to: cssDir.appendingPathComponent("comic.css"), atomically: true, encoding: .utf8)
        
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
        
        var manifestItems: [String] = []
        var spineItems: [String] = []
        manifestItems.append("<item id=\"css\" href=\"css/comic.css\" media-type=\"text/css\"/>")
        manifestItems.append("<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>")
        manifestItems.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        
        var globalPageIndex = 1
        var globalPageCounter = (activeCoverData != nil) ? 2 : 1
        
        // 2.5 Inject Override Cover if Present
        if let coverData = activeCoverData {
            let coverFilename = "cover.jpg"
            let destURL = imagesDir.appendingPathComponent(coverFilename)
            try? coverData.write(to: destURL)
            
            let lang = settings.mangaMode ? "ja" : "en"
            let coverXHTML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(lang)" xml:lang="\(lang)">
            <head>
                <title>Cover</title>
                <meta name="viewport" content="width=1980, height=2640"/>
                <style type="text/css">
                    html, body { margin: 0; padding: 0; width: 100%; height: 100%; background-color: #000000; }
                    img { display: block; width: 100%; height: 100%; }
                </style>
            </head>
            <body epub:type="cover"><img src="../images/\(coverFilename)" alt="Cover"/></body>
            </html>
            """
            try? coverXHTML.write(to: textDir.appendingPathComponent("cover.xhtml"), atomically: true, encoding: .utf8)
            
            manifestItems.append("<item id=\"cover_page\" href=\"text/cover.xhtml\" media-type=\"application/xhtml+xml\"/>")
            manifestItems.append("<item id=\"cover_img\" href=\"images/\(coverFilename)\" media-type=\"image/jpeg\" properties=\"cover-image\"/>")
            spineItems.append("<itemref idref=\"cover_page\" linear=\"no\"/>")
            
            // Note: Cover doesn't increment globalPageCounter because page-spread tags only align content pages
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
                    
                    // Manifest & HTML
                    let htmlName = String(format: "page_%05d.xhtml", globalPageIndex)
                    let lang = settings.mangaMode ? "ja" : "en"
                    let htmlContent = """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(lang)" xml:lang="\(lang)">
                    <head>
                        <meta charset="UTF-8"/>
                        <meta name="viewport" content="width=1980, height=2640"/>
                        <title>Page \(globalPageIndex)</title>
                        <link rel="stylesheet" type="text/css" href="../css/comic.css"/>
                        <style type="text/css">
                            @page { margin: 0; padding: 0; }
                            html, body { margin: 0; padding: 0; width: 100%; height: 100%; background-color: #000000; }
                            .chunk-container { width: 100%; height: 100%; margin: 0; padding: 0; }
                            .page { width: 100%; height: 100%; margin: 0; padding: 0; }
                            .page-image { display: block; width: 100%; height: 100%; }
                        </style>
                    </head>
                    <body>
                        <div class="chunk-container">
                            <div class="page">
                                <img src="../images/\(newName)" class="page-image" alt=""/>
                            </div>
                        </div>
                    </body>
                    </html>
                    """
                    
                    try? htmlContent.write(to: textDir.appendingPathComponent(htmlName), atomically: true, encoding: .utf8)
                    
                    let isFirstPageCover = (globalPageIndex == 1 && activeCoverData == nil)
                    let properties = isFirstPageCover ? " properties=\"cover-image\"" : ""
                    manifestItems.append("<item id=\"page_\(globalPageIndex)\" href=\"text/\(htmlName)\" media-type=\"application/xhtml+xml\"/>")
                    manifestItems.append("<item id=\"img_\(globalPageIndex)\" href=\"images/\(newName)\" media-type=\"image/\(safeExt)\"\(properties)/>")
                    
                    // Apply Dynamic Landscape Spreads Tagging (RTL vs LTR)
                    if globalPageIndex == 1 && activeCoverData == nil {
                        spineItems.append("<itemref idref=\"page_\(globalPageIndex)\" linear=\"no\"/>")
                    } else {
                        let spreadTag: String
                        if globalPageCounter == 1 {
                            spreadTag = ""
                        } else if settings.mangaMode {
                            spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-left\"" : " properties=\"page-spread-right\""
                        } else {
                            spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-right\"" : " properties=\"page-spread-left\""
                        }
                        spineItems.append("<itemref idref=\"page_\(globalPageIndex)\"\(spreadTag)/>")
                    }
                    
                    globalPageIndex += 1
                    globalPageCounter += 1
                }
            }
        }
        
        let firstPageHref = (activeCoverData != nil) ? "text/cover.xhtml" : "text/page_00001.xhtml"
        
        // 4. Metadata (OPF)
        let opfTitle = sourceMetadata?.series ?? sourceMetadata?.title ?? "Merged Comic Collection"
        let rawCreator = sourceMetadata?.writer ?? sourceMetadata?.publisher ?? ""
        let opfCreator = rawCreator.isEmpty ? "Inksync Pro" : rawCreator
        let opfDesc = sourceMetadata?.summary ?? "Omnibus edition generated by Inksync."
        let progression = settings.mangaMode ? "rtl" : "ltr"
        let dateIso = Date().ISO8601Format()
        let originalResolution = "1980x2640"
        let bookUUID = UUID().uuidString
        let coverMeta = (activeCoverData != nil) ? "cover_img" : "img_1"
        
        let opfContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:epub="http://www.idpf.org/2007/ops" unique-identifier="BookID" version="3.0" prefix="rendition: http://www.idpf.org/vocab/rendition/# dcterms: http://purl.org/dc/terms/">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="BookID">urn:uuid:\(bookUUID)</dc:identifier>
                <dc:title>\(opfTitle.xmlEscaped())</dc:title>
                <dc:creator>\(opfCreator.xmlEscaped())</dc:creator>
                <dc:description>\(opfDesc.xmlEscaped())</dc:description>
                <dc:language>\(settings.mangaMode ? "ja" : "en")</dc:language>
                <meta property="dcterms:modified">\(dateIso)</meta>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">auto</meta>
                <meta property="rendition:spread">auto</meta>
                <meta name="fixed-layout" content="true"/>
                <meta name="original-resolution" content="\(originalResolution)"/>
                <meta name="cover" content="\(coverMeta)"/>
            </metadata>
            <manifest>
                \(manifestItems.joined(separator: "\n        "))
            </manifest>
            <spine toc="ncx" page-progression-direction="\(progression)">
                \(spineItems.joined(separator: "\n        "))
            </spine>
            <guide>
                <reference type="cover" title="Cover" href="\(firstPageHref)"/>
                <reference type="text" title="Text" href="\(firstPageHref)"/>
            </guide>
        </package>
        """
        try opfContent.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        
        // 5. Nav
        let lang = settings.mangaMode ? "ja" : "en"
        let navContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(lang)" xml:lang="\(lang)">
        <head><title>Navigation</title><meta charset="utf-8" /></head>
        <body>
            <nav epub:type="toc" id="toc"><h1>Table of Contents</h1><ol><li><a href="\(firstPageHref)">Start Reading</a></li></ol></nav>
            <nav epub:type="landmarks"><h1>Landmarks</h1><ol><li><a epub:type="cover" href="\(firstPageHref)">Cover</a></li><li><a epub:type="bodymatter" href="\(firstPageHref)">Start</a></li></ol></nav>
        </body>
        </html>
        """
        try navContent.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        
        // 5.5 NCX
        let ncxContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head><meta name="dtb:uid" content="urn:uuid:\(bookUUID)"/></head>
            <docTitle><text>\(opfTitle.xmlEscaped())</text></docTitle>
            <navMap>
                <navPoint id="navPoint-1" playOrder="1">
                    <navLabel><text>Start</text></navLabel>
                    <content src="\(firstPageHref)"/>
                </navPoint>
            </navMap>
        </ncx>
        """
        try ncxContent.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)
        
        // 6. Zip
        let metaInfDir = epubDir.appendingPathComponent("META-INF")
        try fileManager.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        
        let archive = try Archive(url: outputURL, accessMode: .create, pathEncoding: .utf8)
        
        // 7. Critical: Inject IDPF Valid Uncompressed Mimetype File
        let mimetypePath = epubDir.appendingPathComponent("mimetype")
        try "application/epub+zip".write(to: mimetypePath, atomically: true, encoding: .ascii)
        try archive.addEntry(with: "mimetype", fileURL: mimetypePath, compressionMethod: .none)
        
        // Inject container.xml second and uncompressed, matching CBZToEPUBConverter
        let containerPath = epubDir.appendingPathComponent("META-INF/container.xml")
        try archive.addEntry(with: "META-INF/container.xml", fileURL: containerPath, compressionMethod: .none)
        
        // 8. Recursive Payload Addition of OEBPS folder contents
        let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey]
        if let enumerator = fileManager.enumerator(at: oebpsDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            while let fileURL = enumerator.nextObject() as? URL {
                try autoreleasepool {
                    var isDirectory: ObjCBool = false
                    fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
                    if isDirectory.boolValue { return }
                    
                    let normalizedFile = fileURL.path.replacingOccurrences(of: "\\", with: "/")
                    let normalizedBase = epubDir.path.replacingOccurrences(of: "\\", with: "/")
                    let prefix = normalizedBase.hasSuffix("/") ? normalizedBase : normalizedBase + "/"
                    let relativePath = normalizedFile.replacingOccurrences(of: prefix, with: "")
                    
                    try archive.addEntry(with: relativePath, fileURL: fileURL, compressionMethod: .deflate)
                }
            }
        }
    }
    
    // MARK: - Smart Omnibus Parsing
    func mergeWithSmartSplit(sourceURLs: [URL], baseOutputName: String, targetDir: URL, settings: ConversionSettings, overrideCoverData: Data? = nil, progressCallback: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
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
        
        // Setup initial Working Dir
        var currentEpubDir = try initializeBlankEPUBDir(volumeOffset: currentVolumeIndex)
        var globalPageIndex = 1
        var globalPageCounter = (activeCoverData != nil) ? 2 : 1
        var manifestItems: [String] = []
        manifestItems.append("<item id=\"css\" href=\"css/comic.css\" media-type=\"text/css\"/>")
        manifestItems.append("<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>")
        manifestItems.append("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
        var spineItems: [String] = []
        
        // Base closure to "Seal" a volume
        let sealCurrentEPUB = { (dirURL: URL, volIdx: Int, mItems: [String], sItems: [String]) throws -> URL in
            let oebps = dirURL.appendingPathComponent("OEBPS")
            
            let progression = settings.mangaMode ? "rtl" : "ltr"
            let dateIso = Date().ISO8601Format()
            let originalResolution = "1980x2640"
            let bookUUID = UUID().uuidString
            let coverMeta = (activeCoverData != nil) ? "cover_img" : "img_1"
            let firstPageHref = (activeCoverData != nil) ? "text/cover.xhtml" : "text/page_00001.xhtml"
            let opfTitle = "\(baseOutputName) (Vol \(volIdx))"
            let opfCreator = "Inksync Pro"
            let opfDesc = "Omnibus edition generated by Inksync."
            
            let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:epub="http://www.idpf.org/2007/ops" unique-identifier="BookID" version="3.0" prefix="rendition: http://www.idpf.org/vocab/rendition/# dcterms: http://purl.org/dc/terms/">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:identifier id="BookID">urn:uuid:\(bookUUID)</dc:identifier>
                    <dc:title>\(opfTitle.xmlEscaped())</dc:title>
                    <dc:creator>\(opfCreator.xmlEscaped())</dc:creator>
                    <dc:description>\(opfDesc.xmlEscaped())</dc:description>
                    <dc:language>\(settings.mangaMode ? "ja" : "en")</dc:language>
                    <meta property="dcterms:modified">\(dateIso)</meta>
                    <meta property="rendition:layout">pre-paginated</meta>
                    <meta property="rendition:orientation">auto</meta>
                    <meta property="rendition:spread">auto</meta>
                    <meta name="fixed-layout" content="true"/>
                    <meta name="original-resolution" content="\(originalResolution)"/>
                    <meta name="cover" content="\(coverMeta)"/>
                </metadata>
                <manifest>
                    \(mItems.joined(separator: "\n        "))
                </manifest>
                <spine toc="ncx" page-progression-direction="\(progression)">
                    \(sItems.joined(separator: "\n        "))
                </spine>
                <guide>
                    <reference type="cover" title="Cover" href="\(firstPageHref)"/>
                    <reference type="text" title="Text" href="\(firstPageHref)"/>
                </guide>
            </package>
            """
            try opf.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
            
            let lang = settings.mangaMode ? "ja" : "en"
            let navContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(lang)" xml:lang="\(lang)">
            <head><title>Navigation</title><meta charset="utf-8" /></head>
            <body>
                <nav epub:type="toc" id="toc"><h1>Table of Contents</h1><ol><li><a href="\(firstPageHref)">Start Reading</a></li></ol></nav>
                <nav epub:type="landmarks"><h1>Landmarks</h1><ol><li><a epub:type="cover" href="\(firstPageHref)">Cover</a></li><li><a epub:type="bodymatter" href="\(firstPageHref)">Start</a></li></ol></nav>
            </body>
            </html>
            """
            try navContent.write(to: oebps.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
            
            let ncxContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
                <head><meta name="dtb:uid" content="urn:uuid:\(bookUUID)"/></head>
                <docTitle><text>\(opfTitle.xmlEscaped())</text></docTitle>
                <navMap>
                    <navPoint id="navPoint-1" playOrder="1">
                        <navLabel><text>Start</text></navLabel>
                        <content src="\(firstPageHref)"/>
                    </navPoint>
                </navMap>
            </ncx>
            """
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
            if let enumerator = fileManager.enumerator(at: oebpsDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                while let fileURL = enumerator.nextObject() as? URL {
                    try autoreleasepool {
                        var isDirectory: ObjCBool = false
                        fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
                        if isDirectory.boolValue { return }
                        
                        let normalizedFile = fileURL.path.replacingOccurrences(of: "\\", with: "/")
                        let normalizedBase = dirURL.path.replacingOccurrences(of: "\\", with: "/")
                        let prefix = normalizedBase.hasSuffix("/") ? normalizedBase : normalizedBase + "/"
                        let relativePath = normalizedFile.replacingOccurrences(of: prefix, with: "")
                        try archive.addEntry(with: relativePath, fileURL: fileURL, compressionMethod: .deflate)
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
                let htmlName = "cover.xhtml"
                let lang = settings.mangaMode ? "ja" : "en"
                let content = """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(lang)" xml:lang="\(lang)">
                <head>
                    <title>Cover</title>
                    <meta name="viewport" content="width=1980, height=2640"/>
                    <style type="text/css">
                        html, body { margin: 0; padding: 0; width: 100%; height: 100%; background-color: #000000; }
                        img { display: block; width: 100%; height: 100%; }
                    </style>
                </head>
                <body epub:type="cover"><img src="../images/\(coverFilename)" alt="Cover"/></body>
                </html>
                """
                try content.write(to: targetOESPSDir.appendingPathComponent("text/\(htmlName)"), atomically: true, encoding: .utf8)
                destManifest.append("<item id=\"cover_page\" href=\"text/\(htmlName)\" media-type=\"application/xhtml+xml\"/>")
                destManifest.append("<item id=\"cover_img\" href=\"images/\(coverFilename)\" media-type=\"image/jpeg\" properties=\"cover-image\"/>")
                destSpine.append("<itemref idref=\"cover_page\" linear=\"no\"/>")
                return 1
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
                let builtEPUBURL = try sealCurrentEPUB(currentEpubDir, currentVolumeIndex, manifestItems, spineItems)
                outputFiles.append(builtEPUBURL)
                
                currentVolumeIndex += 1
                currentBundleBytes = 0
                globalPageIndex = 1
                globalPageCounter = (activeCoverData != nil) ? 2 : 1
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
                    
                    let htmlName = String(format: "page_%05d.xhtml", globalPageIndex)
                    let lang = settings.mangaMode ? "ja" : "en"
                    let htmlContent = """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(lang)" xml:lang="\(lang)">
                    <head>
                        <meta charset="UTF-8"/>
                        <meta name="viewport" content="width=1980, height=2640"/>
                        <title>Page \(globalPageIndex)</title>
                        <link rel="stylesheet" type="text/css" href="../css/comic.css"/>
                        <style type="text/css">
                            @page { margin: 0; padding: 0; }
                            html, body { margin: 0; padding: 0; width: 100%; height: 100%; background-color: #000000; }
                            .chunk-container { width: 100%; height: 100%; margin: 0; padding: 0; }
                            .page { width: 100%; height: 100%; margin: 0; padding: 0; }
                            .page-image { display: block; width: 100%; height: 100%; }
                        </style>
                    </head>
                    <body>
                        <div class="chunk-container">
                            <div class="page">
                                <img src="../images/\(newName)" class="page-image" alt=""/>
                            </div>
                        </div>
                    </body>
                    </html>
                    """
                    try? htmlContent.write(to: activeText.appendingPathComponent(htmlName), atomically: true, encoding: .utf8)
                    
                    let isFirstPageCover = (globalPageIndex == 1 && activeCoverData == nil)
                    let properties = isFirstPageCover ? " properties=\"cover-image\"" : ""
                    manifestItems.append("<item id=\"page_\(globalPageIndex)\" href=\"text/\(htmlName)\" media-type=\"application/xhtml+xml\"/>")
                    manifestItems.append("<item id=\"img_\(globalPageIndex)\" href=\"images/\(newName)\" media-type=\"image/\(safeExt)\"\(properties)/>")
                    
                    // Apply Dynamic Landscape Spreads Tagging (RTL vs LTR)
                    if globalPageIndex == 1 && activeCoverData == nil {
                        spineItems.append("<itemref idref=\"page_\(globalPageIndex)\" linear=\"no\"/>")
                    } else {
                        let spreadTag: String
                        if globalPageCounter == 1 {
                            spreadTag = ""
                        } else if settings.mangaMode {
                            spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-left\"" : " properties=\"page-spread-right\""
                        } else {
                            spreadTag = (globalPageCounter % 2 == 1) ? " properties=\"page-spread-right\"" : " properties=\"page-spread-left\""
                        }
                        spineItems.append("<itemref idref=\"page_\(globalPageIndex)\"\(spreadTag)/>")
                    }
                    
                    globalPageIndex += 1
                    globalPageCounter += 1
                }
            }
            
            currentBundleBytes += issueMB
            try? fileManager.removeItem(at: scratchDir)
            progressCallback(Double(idx + 1) / Double(totalFiles))
        }
        
        if currentBundleBytes > 0 {
            let builtEPUBURL = try sealCurrentEPUB(currentEpubDir, currentVolumeIndex, manifestItems, spineItems)
            outputFiles.append(builtEPUBURL)
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
        let cssContent = """
        @page { margin: 0; padding: 0; }
        html, body { margin: 0; padding: 0; width: 100%; height: 100%; background-color: #000000; }
        .chunk-container { width: 100%; height: 100%; margin: 0; padding: 0; }
        .page { width: 100%; height: 100%; margin: 0; padding: 0; }
        .page-image { display: block; width: 100%; height: 100%; }
        """
        try cssContent.write(to: oebpsDir.appendingPathComponent("css/comic.css"), atomically: true, encoding: .utf8)
        try fileManager.createDirectory(at: newDir.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try "<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".write(to: newDir.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
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
        let ext = srcURL.pathExtension.lowercased()
        if ext == "webp" {
            if let image = UIImage(contentsOfFile: srcURL.path),
               let jpegData = image.jpegData(compressionQuality: settings.compressionQuality.value) {
                try jpegData.write(to: destURL)
            } else {
                let data = try Data(contentsOf: srcURL)
                try data.write(to: destURL)
            }
        } else {
            let data = try Data(contentsOf: srcURL)
            try data.write(to: destURL)
        }
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


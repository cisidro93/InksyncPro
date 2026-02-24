import SwiftUI
import ZIPFoundation

// ============================================================
// SCOPE BOUNDARY — ISOLATED MODULE
// This file is a fully self-contained Panel View conversion
// pipeline. It does NOT import, extend, or modify any logic
// from CBZToEPUBConverter.swift or KF8AZW3Converter.swift.
// ============================================================

// MARK: - Error Types

enum PanelViewError: Error, LocalizedError {
    case noImages
    case archiveCreationFailed
    case nestedAnchorTag(page: Int)
    case percentageCoordinate(page: Int, panel: Int)
    case duplicateID(id: String)
    case nonSequentialOrdinals(page: Int)
    case brokenTargetReference(page: Int, panel: Int)

    var errorDescription: String? {
        switch self {
        case .noImages:                         return "No images found in CBZ archive."
        case .archiveCreationFailed:            return "Could not create output EPUB archive."
        case .nestedAnchorTag(let p):           return "Nested <a> tag detected on page \(p). Panel View will fail."
        case .percentageCoordinate(let p, let n): return "Percentage coordinate detected page \(p) panel \(n). Only px is allowed."
        case .duplicateID(let id):              return "Duplicate element ID '\(id)' detected. Kindle requires globally-unique IDs."
        case .nonSequentialOrdinals(let p):     return "Non-sequential ordinals on page \(p). Ordinals must start at 1."
        case .brokenTargetReference(let p, let n): return "targetId mismatch on page \(p) panel \(n)."
        }
    }
}

// MARK: - Coordinate Transform (Single Canonical Function)

/// Converts a Vision-space panel bounding box to absolute screen pixels.
///
/// Vision origin is **bottom-left**; CSS/Kindle origin is **top-left**.
/// This is the single source of truth for the Y-flip — applied once, never again.
///
/// - Parameters:
///   - box:        CGRect in Vision space (0…1, bottom-left origin)
///   - pageWidth:  Actual image pixel width
///   - pageHeight: Actual image pixel height
/// - Returns:      CGRect in CSS pixel space (top-left origin)
func visionToPixel(_ box: CGRect, pageWidth: CGFloat, pageHeight: CGFloat) -> CGRect {
    let x = box.minX * pageWidth
    let y = (1.0 - box.maxY) * pageHeight   // Y-flip: Vision maxY becomes CSS top
    let w = box.width  * pageWidth
    let h = box.height * pageHeight
    return CGRect(x: x, y: y, width: w, height: h)
}

/// Extends a panel rect by 150% (centered) and clamps to page bounds.
func magnifiedRect(from src: CGRect, pageWidth: CGFloat, pageHeight: CGFloat) -> CGRect {
    let extra = CGPoint(x: src.width * 0.25, y: src.height * 0.25)
    let r = CGRect(
        x: src.minX - extra.x,
        y: src.minY - extra.y,
        width: src.width * 1.5,
        height: src.height * 1.5
    )
    // Clamp to page
    let cx = max(0, min(r.minX, pageWidth  - r.width))
    let cy = max(0, min(r.minY, pageHeight - r.height))
    let cw = min(r.width,  pageWidth  - cx)
    let ch = min(r.height, pageHeight - cy)
    return CGRect(x: cx, y: cy, width: cw, height: ch)
}

// MARK: - Main Converter

/// Isolated Panel View EPUB conversion engine.
/// Produces an Amazon KF8-compliant EPUB 3.0 fixed-layout document
/// with Region Magnification tap targets and 150% magnified panel crops.
///
/// Standard Converter (CBZToEPUBConverter) is untouched: this class
/// is invoked exclusively via the `.proPanelEPUB` pipeline.
class PanelViewEPUBConverter {

    // MARK: Public Interface

    /// Convert a CBZ/CBR source file to a Panel View EPUB.
    ///
    /// - Parameters:
    ///   - sourceURL:  URL of the source CBZ/CBR/ZIP file.
    ///   - settings:   User conversion settings (manga flag, device, quality, split mode).
    ///   - panels:     Dictionary mapping page index (0-based) → array of Vision-space panels.
    ///                 Pages absent from the dictionary are treated as panel-free splash pages.
    ///   - progress:   0…1 progress callback (called on background thread; not Main).
    /// - Returns:      Array of output EPUB URLs written to the app's Documents directory.
    func convert(
        sourceURL: URL,
        settings: ConversionSettings,
        panels: [Int: [PanelExtractor.Panel]],
        progress: @escaping (Double) -> Void
    ) async throws -> [URL] {
        Logger.shared.log("PanelViewEPUBConverter: Starting. Pages with panels: \(panels.count)", category: "PVConverter")

        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // ── Strip all extensions from filename ────────────────────────────────
        var baseFilename = sourceURL.lastPathComponent
        while baseFilename.contains(".") {
            let s = (baseFilename as NSString).deletingPathExtension
            if s == baseFilename { break }
            baseFilename = s
        }

        // ── Step 0: Extract archive ───────────────────────────────────────────
        progress(0.05)
        let extraction = try await ZipUtilities.extractComic(from: sourceURL)
        let tempDir    = extraction.workingDir
        defer { try? fileManager.removeItem(at: tempDir) }

        let imageURLs = extraction.imageURLs
        guard !imageURLs.isEmpty else { throw PanelViewError.noImages }

        // ── Detect Manga ──────────────────────────────────────────────────────
        let comicInfo = ComicInfoParser.parse(from: sourceURL)
        let isManga = settings.mangaMode || (comicInfo?.manga ?? false)
        Logger.shared.log("PanelViewEPUBConverter: Manga=\(isManga)", category: "PVConverter")

        // ── Batch by split mode ───────────────────────────────────────────────
        progress(0.08)
        let batches = buildBatches(imageURLs: imageURLs, settings: settings)
        Logger.shared.log("PanelViewEPUBConverter: \(batches.count) batch(es)", category: "PVConverter")

        var outputURLs: [URL] = []
        let batchCount = Double(batches.count)

        for (batchIdx, batch) in batches.enumerated() {
            let partSuffix = batches.count > 1 ? " (pt \(batchIdx + 1))" : ""
            let batchName  = baseFilename + partSuffix

            // Detect page dimensions from first image in batch
            let pageSize = await resolvePageSize(from: batch.first?.url ?? imageURLs[0])
            let pageW = pageSize.width
            let pageH = pageSize.height

            // Build EPUB directory tree in a temp subfolder
            let buildDir = tempDir.appendingPathComponent("PV_\(batchIdx)")
            let oebpsDir = buildDir.appendingPathComponent("OEBPS")
            let pagesDir = oebpsDir.appendingPathComponent("pages")
            let imagesDir = oebpsDir.appendingPathComponent("images")
            let cssDir   = oebpsDir.appendingPathComponent("css")
            let metaDir  = buildDir.appendingPathComponent("META-INF")
            try fileManager.createDirectory(at: pagesDir,  withIntermediateDirectories: true)
            try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: cssDir,    withIntermediateDirectories: true)
            try fileManager.createDirectory(at: metaDir,   withIntermediateDirectories: true)

            // Step 1: metadata
            let bookUUID = "urn:uuid:\(UUID().uuidString)"

            // Step 2 prep: build page catalog
            var pageCatalog: [PageEntry] = []
            for (localIdx, item) in batch.enumerated() {
                let globalIdx   = item.index
                let pageNum     = globalIdx + 1
                let paddedNum   = String(format: "%03d", pageNum)
                let imageName   = "page\(paddedNum).jpg"
                let xhtmlName   = "page\(paddedNum).xhtml"
                var pagePanels  = panels[globalIdx] ?? []

                // Process image → JPEG
                let imgData = processImage(srcURL: item.url, settings: settings)
                try imgData.write(to: imagesDir.appendingPathComponent(imageName))

                // Resolve actual pixel dimensions per page (may differ from page 1)
                let pageSz = UIImage(data: imgData)?.size ?? pageSize

                // ✅ FIX: On-the-fly Panel Detection
                // If the manifest lacks panels for this page, detect them automatically
                // just like the old legacy converters did.
                if pagePanels.isEmpty && settings.enablePanelSplit {
                    if let image = UIImage(data: imgData) {
                        pagePanels = await PanelExtractor.detectPanels(in: image, mode: .automatic, mangaMode: isManga)
                    }
                }

                // Step 3: Build XHTML
                let xhtml = buildXHTMLPage(
                    pageNum: pageNum,
                    imageName: imageName,
                    panels: pagePanels,
                    pageWidth: pageSz.width,
                    pageHeight: pageSz.height,
                    isManga: isManga
                )
                try xhtml.write(to: pagesDir.appendingPathComponent(xhtmlName), atomically: true, encoding: .utf8)

                pageCatalog.append(PageEntry(
                    localIndex: localIdx,
                    globalIndex: globalIdx,
                    paddedNum: paddedNum,
                    imageName: imageName,
                    xhtmlName: xhtmlName,
                    panelCount: pagePanels.count
                ))

                let batchProgress = 0.1 + (0.55 * Double(localIdx) / Double(batch.count))
                let globalProgress = (Double(batchIdx) + batchProgress) / batchCount
                progress(globalProgress)
            }

            // Step 4: Validation
            try validate(pagesDir: pagesDir, pageCatalog: pageCatalog)

            // Write ancillary files
            try buildCSS().write(to: cssDir.appendingPathComponent("comic.css"), atomically: true, encoding: .utf8)
            try buildContainerXML().write(to: metaDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
            try buildNavXHTML(title: batchName, firstPage: pageCatalog.first?.xhtmlName ?? "page001.xhtml")
                .write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
            try buildTocNCX(title: batchName, uuid: bookUUID, firstPage: pageCatalog.first?.xhtmlName ?? "page001.xhtml")
                .write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

            // Blank page (Manga odd-page handling)
            let needsBlank = isManga && (pageCatalog.count % 2 != 0)
            if needsBlank {
                let blankXHTML = buildBlankXHTML(pageWidth: pageW, pageHeight: pageH)
                try blankXHTML.write(to: pagesDir.appendingPathComponent("blank.xhtml"), atomically: true, encoding: .utf8)
            }

            // Step 1: content.opf (after catalog is known)
            let opf = buildOPF(
                title: batchName,
                uuid: bookUUID,
                pageWidth: Int(pageW),
                pageHeight: Int(pageH),
                isManga: isManga,
                pageCatalog: pageCatalog,
                needsBlank: needsBlank,
                comicInfo: comicInfo
            )
            try opf.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

            // mimetype (first, uncompressed)
            let mimetypePath = buildDir.appendingPathComponent("mimetype")
            try "application/epub+zip".write(to: mimetypePath, atomically: true, encoding: .ascii)

            // Assemble ZIP → .epub
            let outputName = sanitizeFilename(batchName) + ".epub"
            let outputURL  = docs.appendingPathComponent(outputName)
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
            }
            try assembleEPUB(buildDir: buildDir, outputURL: outputURL, oebpsDir: oebpsDir, metaDir: metaDir, mimetypePath: mimetypePath)

            outputURLs.append(outputURL)
            Logger.shared.log("PanelViewEPUBConverter: Produced \(outputName)", category: "PVConverter")
            progress((Double(batchIdx + 1)) / batchCount * 0.95)
        }

        progress(1.0)
        return outputURLs
    }

    // MARK: - Step 1: OPF Synthesis

    private func buildOPF(
        title: String,
        uuid: String,
        pageWidth: Int,
        pageHeight: Int,
        isManga: Bool,
        pageCatalog: [PageEntry],
        needsBlank: Bool,
        comicInfo: ComicInfoParser.ComicInfo?
    ) -> String {
        let isPortrait   = pageHeight > pageWidth
        let orientation  = isPortrait ? "portrait" : "landscape"
        let writingMode  = isManga ? "horizontal-rl" : "horizontal-lr"
        let spreadMode   = "landscape"
        let author       = comicInfo?.writer ?? "Unknown"
        let pubDate      = ISO8601DateFormatter().string(from: Date()).prefix(10)

        // Manifest items
        var manifestItems: [String] = [
            #"<item id="nav"  href="nav.xhtml"  media-type="application/xhtml+xml" properties="nav"/>"#,
            #"<item id="ncx"  href="toc.ncx"    media-type="application/x-dtbncx+xml"/>"#,
            #"<item id="css"  href="css/comic.css" media-type="text/css"/>"#
        ]
        for entry in pageCatalog {
            manifestItems.append(#"<item id="img-\#(entry.paddedNum)" href="images/\#(entry.imageName)" media-type="image/jpeg"\#(entry.localIndex == 0 ? " properties=\"cover-image\"" : "")/>"#)
            manifestItems.append(#"<item id="page\#(entry.paddedNum)" href="pages/\#(entry.xhtmlName)" media-type="application/xhtml+xml"/>"#)
        }
        if needsBlank {
            manifestItems.append(#"<item id="page-blank" href="pages/blank.xhtml" media-type="application/xhtml+xml"/>"#)
        }

        // Step 2: Spine with synthetic spreads
        let spineItems = buildSpineItems(pageCatalog: pageCatalog, isManga: isManga, needsBlank: needsBlank)

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0"
                 xmlns="http://www.idpf.org/2007/opf"
                 unique-identifier="BookID"
                 prefix="rendition: http://www.idpf.org/vocab/rendition/#">

          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
                    xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:title>\(title.xmlEscaped())</dc:title>
            <dc:creator>\(author.xmlEscaped())</dc:creator>
            <dc:identifier id="BookID">\(uuid)</dc:identifier>
            <dc:language>\(isManga ? "ja" : "en")</dc:language>
            <dc:date>\(pubDate)</dc:date>
            <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta>

            <!-- Fixed Layout — ALL required for Kindle Panel View -->
            <meta name="fixed-layout" content="true"/>
            <meta name="original-resolution" content="\(pageWidth)x\(pageHeight)"/>
            <meta name="orientation-lock" content="\(orientation)"/>
            <meta name="book-type" content="comic"/>
            <meta name="RegionMagnification" content="true"/>
            <meta name="region-all-mag-adp" content="1"/>
            <meta name="cover" content="img-001"/>
            <meta name="zero-gutter" content="true"/>
            <meta name="zero-margin" content="true"/>

            <!-- Directional — CRITICAL: horizontal-rl reverses Kindle tap zones for manga -->
            <meta name="primary-writing-mode" content="\(writingMode)"/>

            <!-- EPUB 3 rendition properties -->
            <meta property="rendition:layout">pre-paginated</meta>
            <meta property="rendition:orientation">\(orientation)</meta>
            <meta property="rendition:spread">\(spreadMode)</meta>
          </metadata>

          <manifest>
            \(manifestItems.joined(separator: "\n    "))
          </manifest>

          <spine toc="ncx" page-progression-direction="\(isManga ? "rtl" : "ltr")">
            \(spineItems.joined(separator: "\n    "))
          </spine>

          <guide>
            <reference type="cover" title="Cover" href="pages/\(pageCatalog.first?.xhtmlName ?? "page001.xhtml")"/>
            <reference type="start"  title="Start"  href="pages/\(pageCatalog.first?.xhtmlName ?? "page001.xhtml")"/>
          </guide>

        </package>
        """
    }

    // MARK: - Step 2: Spine Builder

    /// Synthesises spine `<itemref>` entries with correct spread properties.
    ///
    /// Western (LTR):
    ///   page1 → page-spread-left, page2 → page-spread-right, repeat
    ///
    /// Manga (RTL):
    ///   cover → facing-page-right (linear=no)
    ///   page1 → facing-page-right, page2 → facing-page-left  (first pair)
    ///   page3 → page-spread-right, page4 → page-spread-left   (subsequent pairs)
    ///   If odd total → append blank with layout-blank
    private func buildSpineItems(pageCatalog: [PageEntry], isManga: Bool, needsBlank: Bool) -> [String] {
        var items: [String] = []

        if isManga {
            for (idx, entry) in pageCatalog.enumerated() {
                let idref = "page\(entry.paddedNum)"
                let isFirst = idx == 0
                if isFirst {
                    // Cover in manga: linear=no, facing-page-right
                    items.append(#"<itemref idref="\#(idref)" properties="facing-page-right" linear="no"/>"#)
                } else {
                    // Position within remaining pages (0-based after the cover)
                    let pos = idx - 1
                    let isFirstPair = (pos < 2)
                    let isEvenSlot  = (pos % 2 == 0) // even = right page in RTL

                    if isFirstPair {
                        let prop = isEvenSlot ? "facing-page-right" : "facing-page-left"
                        items.append(#"<itemref idref="\#(idref)" properties="\#(prop)"/>"#)
                    } else {
                        let prop = isEvenSlot ? "page-spread-right" : "page-spread-left"
                        items.append(#"<itemref idref="\#(idref)" properties="\#(prop)"/>"#)
                    }
                }
            }
            if needsBlank {
                items.append(#"<itemref idref="page-blank" properties="layout-blank"/>"#)
            }
        } else {
            // Western: cover is page-spread-center, then alternating left/right
            for (idx, entry) in pageCatalog.enumerated() {
                let idref = "page\(entry.paddedNum)"
                if idx == 0 {
                    items.append(#"<itemref idref="\#(idref)" properties="page-spread-center" linear="no"/>"#)
                } else {
                    let prop = (idx % 2 == 1) ? "page-spread-left" : "page-spread-right"
                    items.append(#"<itemref idref="\#(idref)" properties="\#(prop)"/>"#)
                }
            }
        }
        return items
    }

    // MARK: - Step 3: XHTML Page Builder

    /// Generates a single XHTML page document following the required DOM structure:
    ///   1. Base image div
    ///   2. Tap-target-container divs (one per panel, sibling to magnify divs)
    ///   3. MagTargetParent divs with 150%-crop background (sibling to tap targets)
    ///
    /// All coordinates are expressed in **pixels (px)**. No percentages allowed.
    private func buildXHTMLPage(
        pageNum: Int,
        imageName: String,
        panels: [PanelExtractor.Panel],
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        isManga: Bool
    ) -> String {
        let W = Int(pageWidth)
        let H = Int(pageHeight)

        // Ordinal direction: Manga reads right-to-left so panels arrive pre-sorted
        // by PanelExtractor.clusterAndSortPanels(mangaMode:).
        // We just assign 1-based ordinals in array order.
        var tapTargets    = ""
        var magnifyBlocks = ""

        for (panelIdx, panel) in panels.enumerated() {
            let ordinal = panelIdx + 1
            let srcID   = "page_\(pageNum)-panel_\(ordinal)-source"
            let magID   = "page_\(pageNum)-panel_\(ordinal)-magTargetParent"
            let innerID = "page_\(pageNum)-panel_\(ordinal)-magTarget"

            // Convert Vision → pixel space (single canonical transform)
            let pxRect  = visionToPixel(panel.boundingBox, pageWidth: pageWidth, pageHeight: pageHeight)
            let magRect = magnifiedRect(from: pxRect, pageWidth: pageWidth, pageHeight: pageHeight)

            let tx = Int(pxRect.minX); let ty = Int(pxRect.minY)
            let tw = Int(pxRect.width); let th = Int(pxRect.height)
            let mx = Int(magRect.minX); let my = Int(magRect.minY)
            let mw = Int(magRect.width); let mh = Int(magRect.height)

            // Background-position: how far to offset the full page image inside the magnified div
            // so only the panel artwork is visible through the overflow:hidden clip.
            let bgX = Int(pxRect.minX - magRect.minX)
            let bgY = Int(pxRect.minY - magRect.minY)

            // JSON attribute — no nested quotes, no % characters
            let jsonAttr = #"{"targetId":"\#(magID)","ordinal":\#(ordinal)}"#

            // Tap target (VALIDATION RULE: <a> is inside tap-target-container div, NOT inside another <a>)
            tapTargets += """
                  <!-- Panel \(ordinal) tap target -->
                  <div id="\(srcID)" class="tap-target-container" style="position:absolute; top:\(ty)px; left:\(tx)px; width:\(tw)px; height:\(th)px; z-index:10;">
                    <a class="app-amzn-magnify" data-app-amzn-magnify='\(jsonAttr)' style="display:block; width:100%; height:100%;"></a>
                  </div>\n
            """

            // Magnified panel (sibling to tap target, NOT nested inside it)
            magnifyBlocks += """
                  <!-- Panel \(ordinal) magnified view (150% crop, background-image clip) -->
                  <div id="\(magID)" class="target-mag-parent" style="position:absolute; top:\(my)px; left:\(mx)px; width:\(mw)px; height:\(mh)px; z-index:5; overflow:hidden; display:none;">
                    <div class="target-mag-lb"></div>
                    <div id="\(innerID)" class="target-mag" style="position:absolute; top:0; left:0; width:\(mw)px; height:\(mh)px; background-image:url(../images/\(imageName)); background-size:\(W)px \(H)px; background-position:-\(bgX)px -\(bgY)px; background-repeat:no-repeat;"></div>
                  </div>\n
            """
        }

        // Pages with no panels: Kindle performs 2×2 Virtual Panel automatically.
        let panelSection = panels.isEmpty ? "    <!-- No panels: Kindle will apply 2×2 Virtual Panel fallback -->\n" : (tapTargets + "\n" + magnifyBlocks)

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head>
            <title>Page \(pageNum)</title>
            <meta name="viewport" content="width=\(W), height=\(H)"/>
            <link rel="stylesheet" type="text/css" href="../css/comic.css"/>
          </head>
          <body>
            <!-- 1. BASE IMAGE -->
            <div class="page">
              <img src="../images/\(imageName)" alt="Page \(pageNum)" class="page-image"/>
            </div>

        \(panelSection)
          </body>
        </html>
        """
    }

    // MARK: - Step 4: Pre-Package Validator

    /// Reads every generated XHTML file and enforces all Amazon Panel View rules.
    private func validate(pagesDir: URL, pageCatalog: [PageEntry]) throws {
        var seenIDs = Set<String>()

        for entry in pageCatalog {
            let fileURL = pagesDir.appendingPathComponent(entry.xhtmlName)
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let pageNum = entry.globalIndex + 1

            // Rule 1: no nested <a> tags
            // A nested anchor would look like <a ...><a ...> with any content between.
            if content.range(of: #"<a[^>]*>(?:(?!</a>).)*<a"#, options: .regularExpression) != nil {
                throw PanelViewError.nestedAnchorTag(page: pageNum)
            }

            // Rule 2: no percentage coordinates in inline styles
            // We only check inside style="" attributes; CSS file uses % for font sizes etc.
            let stylePattern = #"style="[^"]*\d+%[^"]*""#
            if content.range(of: stylePattern, options: .regularExpression) != nil {
                throw PanelViewError.percentageCoordinate(page: pageNum, panel: -1)
            }

            // Rule 3: globally unique element IDs
            let idPattern = #"id="([^"]+)""#
            let regex = try? NSRegularExpression(pattern: idPattern)
            let range = NSRange(content.startIndex..., in: content)
            for match in (regex?.matches(in: content, range: range) ?? []) {
                if let r = Range(match.range(at: 1), in: content) {
                    let id = String(content[r])
                    if seenIDs.contains(id) {
                        throw PanelViewError.duplicateID(id: id)
                    }
                    seenIDs.insert(id)
                }
            }

            // Rule 4: targetId in JSON must match an actual element id
            let jsonPattern = #""targetId":"([^"]+)""#
            let jsonRegex = try? NSRegularExpression(pattern: jsonPattern)
            var panelIndex = 0
            for match in (jsonRegex?.matches(in: content, range: range) ?? []) {
                panelIndex += 1
                if let r = Range(match.range(at: 1), in: content) {
                    let targetId = String(content[r])
                    if !seenIDs.contains(targetId) {
                        // targetId may have been registered in a later page — validate after all IDs are collected.
                        // We do a simple in-page check: the target div must exist in the same file.
                        if !content.contains("id=\"\(targetId)\"") {
                            throw PanelViewError.brokenTargetReference(page: pageNum, panel: panelIndex)
                        }
                    }
                }
            }

            // Rule 5: ordinals start at 1 and are sequential
            if entry.panelCount > 0 {
                let ordPattern = #""ordinal":(\d+)"#
                let ordRegex = try? NSRegularExpression(pattern: ordPattern)
                let ordMatches = ordRegex?.matches(in: content, range: range) ?? []
                var expected = 1
                for match in ordMatches {
                    if let r = Range(match.range(at: 1), in: content) {
                        let value = Int(content[r]) ?? 0
                        if value != expected {
                            throw PanelViewError.nonSequentialOrdinals(page: pageNum)
                        }
                        expected += 1
                    }
                }
            }
        }

        Logger.shared.log("PanelViewEPUBConverter: Validation passed (\(pageCatalog.count) pages, \(seenIDs.count) unique IDs)", category: "PVConverter")
    }

    // MARK: - Ancillary File Builders

    private func buildCSS() -> String {
        """
        /* PanelView EPUB Stylesheet — fixed-layout Kindle comic */
        * { margin: 0; padding: 0; border: 0; }
        html, body { width: 100%; height: 100%; overflow: hidden; background-color: #000000; }
        .page { position: absolute; width: 100%; height: 100%; }
        .page-image { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }

        /* Tap target container: invisible overlay, absolute pixel positioned */
        .tap-target-container { position: absolute; }
        a.app-amzn-magnify { display: block; width: 100%; height: 100%; text-decoration: none; background: transparent; }

        /* Magnified panel container (shown by Kindle when tap fires) */
        .target-mag-parent { position: absolute; overflow: hidden; }
        .target-mag-lb { position: absolute; width: 100%; height: 100%; background: transparent; }
        .target-mag { position: absolute; background-repeat: no-repeat; }
        """
    }

    private func buildContainerXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
    }

    private func buildNavXHTML(title: String, firstPage: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
          <head><meta charset="UTF-8"/><title>\(title.xmlEscaped())</title></head>
          <body>
            <nav epub:type="toc" id="toc">
              <ol><li><a href="pages/\(firstPage)">Start Reading</a></li></ol>
            </nav>
            <nav epub:type="landmarks">
              <ol><li><a epub:type="bodymatter" href="pages/\(firstPage)">Start</a></li></ol>
            </nav>
          </body>
        </html>
        """
    }

    private func buildTocNCX(title: String, uuid: String, firstPage: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="\(uuid)"/>
            <meta name="dtb:depth" content="1"/>
            <meta name="dtb:totalPageCount" content="0"/>
            <meta name="dtb:maxPageNumber" content="0"/>
          </head>
          <docTitle><text>\(title.xmlEscaped())</text></docTitle>
          <navMap>
            <navPoint id="navpoint-1" playOrder="1">
              <navLabel><text>Start</text></navLabel>
              <content src="pages/\(firstPage)"/>
            </navPoint>
          </navMap>
        </ncx>
        """
    }

    private func buildBlankXHTML(pageWidth: CGFloat, pageHeight: CGFloat) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head>
            <title>Blank</title>
            <meta name="viewport" content="width=\(Int(pageWidth)), height=\(Int(pageHeight))"/>
          </head>
          <body style="background-color:#000000;"></body>
        </html>
        """
    }

    // MARK: - ZIP Assembly (strict entry order per EPUB spec)

    private func assembleEPUB(buildDir: URL, outputURL: URL, oebpsDir: URL, metaDir: URL, mimetypePath: URL) throws {
        guard let archive = Archive(url: outputURL, accessMode: .create) else {
            throw PanelViewError.archiveCreationFailed
        }
        let fm = FileManager.default

        // 1. mimetype — MUST be first, stored uncompressed
        try archive.addEntry(with: "mimetype", fileURL: mimetypePath, compressionMethod: .none)

        // 2. META-INF/container.xml
        try archive.addEntry(with: "META-INF/container.xml",
                             fileURL: metaDir.appendingPathComponent("container.xml"),
                             compressionMethod: .deflate)

        // 3. OEBPS root files (opf, toc, nav, css)
        for filename in ["content.opf", "toc.ncx", "nav.xhtml"] {
            let url = oebpsDir.appendingPathComponent(filename)
            if fm.fileExists(atPath: url.path) {
                try archive.addEntry(with: "OEBPS/\(filename)", fileURL: url, compressionMethod: .deflate)
            }
        }
        let cssURL = oebpsDir.appendingPathComponent("css/comic.css")
        if fm.fileExists(atPath: cssURL.path) {
            try archive.addEntry(with: "OEBPS/css/comic.css", fileURL: cssURL, compressionMethod: .deflate)
        }

        // 4. images
        let imagesDir = oebpsDir.appendingPathComponent("images")
        if let imageFiles = try? fm.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: nil) {
            for imgURL in imageFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try archive.addEntry(with: "OEBPS/images/\(imgURL.lastPathComponent)", fileURL: imgURL, compressionMethod: .deflate)
            }
        }

        // 5. pages
        let pagesDir = oebpsDir.appendingPathComponent("pages")
        if let pageFiles = try? fm.contentsOfDirectory(at: pagesDir, includingPropertiesForKeys: nil) {
            for pageURL in pageFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try archive.addEntry(with: "OEBPS/pages/\(pageURL.lastPathComponent)", fileURL: pageURL, compressionMethod: .deflate)
            }
        }
    }

    // MARK: - Helpers

    private struct PageEntry {
        let localIndex: Int
        let globalIndex: Int
        let paddedNum: String
        let imageName: String
        let xhtmlName: String
        let panelCount: Int
    }

    private func buildBatches(imageURLs: [URL], settings: ConversionSettings) -> [[(url: URL, index: Int)]] {
        var batches: [[(url: URL, index: Int)]] = []
        var current: [(url: URL, index: Int)] = []
        let limit = settings.splitMode.limit

        // Use file sizes on disk (pre-processing) as a size estimate for batching
        var currentSize: Int64 = 0
        for (idx, url) in imageURLs.enumerated() {
            let sz = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) }) ?? 0
            if limit != Int64.max && (currentSize + sz + 500_000) > limit && !current.isEmpty {
                batches.append(current)
                current = []; currentSize = 0
            }
            current.append((url: url, index: idx))
            currentSize += sz ?? 0
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private func processImage(srcURL: URL, settings: ConversionSettings) -> Data {
        let ext = srcURL.pathExtension.lowercased()
        let kindleSafe = ["jpg", "jpeg"] // PNG is NOT safe per KF8 spec
        let needsCompression = settings.compressionQuality != .high

        if needsCompression, let image = UIImage(contentsOfFile: srcURL.path) {
            return image.jpegData(compressionQuality: settings.compressionQuality.value) ?? Data()
        }
        if kindleSafe.contains(ext), let data = try? Data(contentsOf: srcURL) {
            return data
        }
        // Force JPEG for PNG, WebP, HEIC, AVIF, etc.
        if let image = UIImage(contentsOfFile: srcURL.path),
           let jpeg = image.jpegData(compressionQuality: 0.92) {
            return jpeg
        }
        return (try? Data(contentsOf: srcURL)) ?? Data()
    }

    private func resolvePageSize(from url: URL) async -> CGSize {
        return await Task.detached(priority: .userInitiated) {
            if let img = UIImage(contentsOfFile: url.path) { return img.size }
            return CGSize(width: 1080, height: 1620)
        }.value
    }

    private func sanitizeFilename(_ name: String) -> String {
        name.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_")).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "  ", with: " ")
            .prefix(120)
            .description
    }
}

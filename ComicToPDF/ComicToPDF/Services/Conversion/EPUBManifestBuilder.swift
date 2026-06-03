import Foundation

/// Defines standard XML and XHTML string generation layouts for EPUB processing.
/// Extracted from main converters to reduce length and adhere to SOLID principles.
public struct EPUBManifestBuilder {

    public static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        </rootfiles>
    </container>
    """

    public static let cssContent = """
    @page { margin: 0; padding: 0; }
    body { margin: 0; padding: 0; background-color: #000000; }
    .content-container { display: flex; justify-content: center; align-items: center; width: 100vw; height: 100vh; margin: 0; padding: 0; }
    .page { position: absolute; width: 100%; height: 100%; margin: 0; padding: 0; }
    img.comic-page { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
    a.app-amzn-magnify { display: block; position: absolute; z-index: 10; text-decoration: none; background: transparent; }
    .panel-source { position: absolute; width: 100%; height: 100%; background: transparent; }
    .panel-target { position: absolute; z-index: 5; pointer-events: none; background: transparent; }
    """

    public static func buildCoverXHTML(coverFilename: String) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Cover</title><style type="text/css">
        body { margin: 0; padding: 0; text-align: center; background-color: #000; }
        img { max-width: 100%; max-height: 100%; height: auto; }
        </style></head>
        <body><img src="../images/\(coverFilename)" alt="Cover"/></body>
        </html>
        """
    }

    /// Generates a nav.xhtml pointing to the correct first content page.
    /// - Parameter firstPageHref: The href of the first spine item, e.g. "text/page_0001.xhtml"
    ///   or "text/cover.xhtml" when a badged cover is prepended.
    public static func buildNavContent(firstPageHref: String = "text/page_0001.xhtml") -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
        <head><title>Navigation</title><meta charset="utf-8" /></head>
        <body>
            <nav epub:type="toc" id="toc"><h1>Table of Contents</h1><ol><li><a href="\(firstPageHref)">Start Reading</a></li></ol></nav>
            <nav epub:type="landmarks"><h1>Landmarks</h1><ol><li><a epub:type="cover" href="\(firstPageHref)">Cover</a></li><li><a epub:type="bodymatter" href="\(firstPageHref)">Start</a></li></ol></nav>
        </body>
        </html>
        """
    }

    @available(*, deprecated, renamed: "buildNavContent(firstPageHref:)")
    public static let navContent = buildNavContent()

    public static func buildNCXContent(bookUUID: String, baseFilename: String, firstPageHref: String = "text/page_0001.xhtml") -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head><meta name="dtb:uid" content="urn:uuid:\(bookUUID)"/></head>
            <docTitle><text>\(baseFilename)</text></docTitle>
            <navMap>
                <navPoint id="navPoint-1" playOrder="1">
                    <navLabel><text>Start</text></navLabel>
                    <content src="\(firstPageHref)"/>
                </navPoint>
            </navMap>
        </ncx>
        """
    }

    public static func buildOPFContent(
        bookUUID: String,
        baseFilename: String,
        batchIndex: Int,
        hasCoverData: Bool,
        manifestItems: [String],
        spineItems: [String],
        isManga: Bool,
        firstPageHref: String = "text/page_0001.xhtml"
    ) -> String {
        let modified = ISO8601DateFormatter().string(from: Date())
        let coverMeta = (batchIndex > 0 && hasCoverData) ? "cover_reused_img" : "img_1"
        let direction = isManga ? "rtl" : "ltr"
        // Kindle Scribe Colorsoft native B&W resolution: 1980x2640 (300ppi, portrait).
        // The original-resolution meta is required by Amazon's KF8 fixed-layout spec so
        // Kindle can pre-scale images to native pixels rather than stretching from an
        // unknown source size. Without it renders are blurry on high-DPI screens.
        let originalResolution = "1980x2640"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:epub="http://www.idpf.org/2007/ops" unique-identifier="BookID" version="3.0" prefix="rendition: http://www.idpf.org/vocab/rendition/# dcterms: http://purl.org/dc/terms/">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="BookID">urn:uuid:\(bookUUID)</dc:identifier>
                <dc:title>\(baseFilename.xmlEscaped())</dc:title>
                <dc:language>\(isManga ? "ja" : "en")</dc:language>
                <meta property="dcterms:modified">\(modified)</meta>
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
            <spine toc="ncx" page-progression-direction="\(direction)">
                \(spineItems.joined(separator: "\n        "))
            </spine>
            <guide>
                <reference type="cover" title="Cover" href="\(firstPageHref)"/>
                <reference type="text" title="Text" href="\(firstPageHref)"/>
            </guide>
        </package>
        """
    }

    public static func buildChunkXHTML(chunkIndex: Int, images: [String], title: String, bookUUID: String? = nil, pageIndex: Int? = nil) -> String {
        let imageElements = images.enumerated().map { _, imageName in
            """
                <div class="page">
                    <img src="../images/\(imageName)" class="page-image" alt="Page Image"/>
                </div>
            """
        }.joined(separator: "\n")

        // NOTE: The tracking pixel (http://LOCAL_IP:8080/page_sync?...) has been removed.
        // Amazon's Send to Kindle scanner rejects EPUBs containing embedded remote HTTP
        // requests, producing error E999. Reading-position sync is handled entirely
        // in-app via the PPLReaderView page-turn callback chain.

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head>
            <meta charset="UTF-8"/>
            <!-- Kindle KF8 fixed-layout: viewport MUST use integer pixel values matching
                 the original-resolution OPF meta. 1980x2640 = Kindle Scribe Colorsoft native B&W.
                 "100vw / 100vh" is valid CSS but not a valid viewport content string and
                 causes Kindle to ignore the declaration entirely. -->
            <meta name="viewport" content="width=1980, height=2640"/>
            <title>\(title)</title>
            <style>
                /* @page size MUST match original-resolution to prevent the Kindle 5.19.x
                   'death margin' layout regression — without an explicit size the firmware
                   allocates its own page box and adds unwanted whitespace. */
                @page { margin: 0; padding: 0; size: 1980px 2640px; }
                /* amzn-kf8: classic Kindle format (sideloaded AZW3/MOBI) */
                @media amzn-kf8 { body { margin: 0 !important; padding: 0 !important; } }
                /* amzn-kfx: Send to Kindle conversion target since 2022 */
                @media amzn-kfx { body { margin: 0 !important; padding: 0 !important; } }
                /* position:fixed pins body to viewport origin, suppressing sub-pixel
                   margin artifacts on the Scribe Colorsoft IGZO display driver. */
                html, body { margin: 0; padding: 0; background-color: #000000; overflow: hidden; position: fixed; top: 0; left: 0; width: 100%; height: 100%; }
                .chunk-container { display: block; width: 100%; height: 100%; margin: 0; padding: 0; }
                .page { display: block; width: 100%; height: 100%; margin: 0; padding: 0; }
                .page-image { display: block; width: 100%; height: 100%; object-fit: contain; object-position: center; }
            </style>
        </head>
        <body>
            <div class="chunk-container">
            \(imageElements)
            </div>
        </body>
        </html>
        """
    }
}

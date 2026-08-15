import Foundation

/// Defines standard XML and XHTML string generation layouts for EPUB processing.
/// Extracted from main converters to reduce length and adhere to SOLID principles.
public struct EPUBManifestBuilder {

    public static let containerXML = """
    <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """

    public static let cssContent = """
    @page { margin: 0; padding: 0; }
    html, body { margin: 0; padding: 0; width: 100%; height: 100%; background-color: #000000; }
    .chunk-container { width: 100%; height: 100%; margin: 0; padding: 0; }
    .page { width: 100%; height: 100%; margin: 0; padding: 0; }
    .page-image { display: block; width: 100%; height: 100%; }
    """

    public static func buildCoverXHTML(coverFilename: String, isManga: Bool = false) -> String {
        // lang is intentionally fixed to "en" regardless of manga mode.
        // Amazon's cloud converter routes lang="ja" through a CJK layout pipeline
        // that fails with E999 on fixed-layout EPUBs (regressed in commit e953c38b).
        // Reading direction is controlled by page-progression-direction on the spine,
        // not by xml:lang. Commit 031174fd resolved E999 by fixing lang to "en".
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
        <head>
            <meta name="viewport" content="width=1980, height=2640"/>
            <title>Cover</title>
            <style type="text/css">
            html, body { margin: 0; padding: 0; width: 100%; height: 100%; background-color: #000000; }
            img { display: block; width: 100%; height: 100%; }
            </style>
        </head>
        <body epub:type="cover"><img src="../images/\(coverFilename)" alt="Cover"/></body>
        </html>
        """
    }

    /// Generates a nav.xhtml pointing to the correct first content page.
    /// - Parameter firstPageHref: The href of the first spine item, e.g. "text/page_0001.xhtml"
    ///   or "text/cover.xhtml" when a badged cover is prepended.
    public static func buildNavContent(firstPageHref: String = "text/page_0001.xhtml", isManga: Bool = false) -> String {
        // lang fixed to "en" — see buildCoverXHTML comment. isManga param kept for
        // call-site compatibility but does not affect the output language tag.
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
            <docTitle><text>\(baseFilename.xmlEscaped())</text></docTitle>
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
        coverMetaID: String?,
        manifestItems: [String],
        spineItems: [String],
        isManga: Bool,
        firstPageHref: String = "text/page_0001.xhtml",
        hasLandscapeSpreads: Bool = false,
        author: String? = nil
    ) -> String {
        let modified = ISO8601DateFormatter().string(from: Date())
        let direction = isManga ? "rtl" : "ltr"
        
        let authorName: String
        if let explicitAuthor = author?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitAuthor.isEmpty {
            authorName = explicitAuthor
        } else {
            authorName = "Unknown Author"
        }
        
        let coverMetaTag: String
        if let cid = coverMetaID {
            coverMetaTag = "\n                <meta name=\"cover\" content=\"\(cid)\"/>"
        } else {
            coverMetaTag = ""
        }
        
        let resolutionMeta = hasLandscapeSpreads ? "" : "\n                <meta name=\"original-resolution\" content=\"1980x2640\"/>"
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:epub="http://www.idpf.org/2007/ops" unique-identifier="BookID" version="3.0" prefix="rendition: http://www.idpf.org/vocab/rendition/# dcterms: http://purl.org/dc/terms/">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="BookID">urn:uuid:\(bookUUID)</dc:identifier>
                <dc:title>\(baseFilename.xmlEscaped())</dc:title>
                <dc:creator>\(authorName.xmlEscaped())</dc:creator>
                <dc:description>Omnibus edition generated by Inksync.</dc:description>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">\(modified)</meta>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">auto</meta>
                <meta property="rendition:spread">auto</meta>
                <meta name="fixed-layout" content="true"/>\(resolutionMeta)\(coverMetaTag)
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

    public static func buildChunkXHTML(chunkIndex: Int, images: [String], title: String, bookUUID: String? = nil, pageIndex: Int? = nil, isManga: Bool = false, pageWidth: Int = 1980, pageHeight: Int = 2640) -> String {
        let imageElements = images.enumerated().map { _, imageName in
            """
                <div class="page">
                    <img src="../images/\(imageName)" class="page-image" alt="Page Image"/>
                </div>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
        <head>
            <meta charset="UTF-8"/>
            <meta name="viewport" content="width=\(pageWidth), height=\(pageHeight)"/>
            <title>\(title)</title>
            <style type="text/css">
                html, body { margin: 0; padding: 0; width: 100%; height: 100%; background-color: #000000; }
                .chunk-container { width: 100%; height: 100%; margin: 0; padding: 0; }
                .page { width: 100%; height: 100%; margin: 0; padding: 0; }
                .page-image { display: block; width: 100%; height: 100%; }
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

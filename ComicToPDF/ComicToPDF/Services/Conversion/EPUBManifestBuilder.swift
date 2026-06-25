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
    body { margin: 0; padding: 0; width: 100vw; height: 100vh; background-color: #000000; }
    div.svg-wrapper { width: 100%; height: 100%; margin: 0; padding: 0; text-align: center; }
    img { height: 100%; width: auto; max-width: 100%; object-fit: contain; }
    """

    public static func buildCoverXHTML(coverFilename: String, isManga: Bool = false) -> String {
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
    public static func buildNavContent(firstPageHref: String = "text/page_0001.xhtml", isManga: Bool = false) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
        <head>
            <title>Navigation</title>
            <meta charset="utf-8" />
        </head>
        <body>
            <nav epub:type="toc" id="toc">
                <h1>Table of Contents</h1>
                <ol>
                    <li><a href="\(firstPageHref)">Start Reading</a></li>
                </ol>
            </nav>
            <nav epub:type="landmarks">
                <h1>Landmarks</h1>
                <ol>
                    <li><a epub:type="cover" href="\(firstPageHref)">Cover</a></li>
                    <li><a epub:type="bodymatter" href="\(firstPageHref)">Start</a></li>
                </ol>
            </nav>
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
        coverMetaID: String,
        manifestItems: [String],
        spineItems: [String],
        isManga: Bool,
        firstPageHref: String = "text/page_0001.xhtml"
    ) -> String {
        let direction = isManga ? "rtl" : "ltr"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookID" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="BookID">urn:uuid:\(bookUUID)</dc:identifier>
                <dc:title>\(baseFilename.xmlEscaped())</dc:title>
                <dc:creator>Inksync Pro</dc:creator>
                <dc:language>en</dc:language>
                <meta name="comic-panel-view" content="guided"/>
                <meta name="cover" content="\(coverMetaID)"/>
            </metadata>
            <manifest>
                \(manifestItems.joined(separator: "\n        "))
            </manifest>
            <spine page-progression-direction="\(direction)">
                \(spineItems.joined(separator: "\n        "))
            </spine>
            <guide>
                <reference type="cover" title="Cover" href="\(firstPageHref)"/>
                <reference type="text" title="Text" href="\(firstPageHref)"/>
            </guide>
        </package>
        """
    }

    public static func buildChunkXHTML(chunkIndex: Int, images: [String], title: String, bookUUID: String? = nil, pageIndex: Int? = nil, isManga: Bool = false) -> String {
        let imageElements = images.enumerated().map { _, imageName in
            """
                <div class="svg-wrapper">
                    <img src="../images/\(imageName)" alt="Page Image"/>
                </div>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
            <title>\(title)</title>
            <meta name="viewport" content="width=1000, height=1500, initial-scale=1.0"/>
            <link rel="stylesheet" type="text/css" href="../css/comic.css"/>
        </head>
        <body>
        \(imageElements)
        </body>
        </html>
        """
    }
}

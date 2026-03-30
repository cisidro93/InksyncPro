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

    public static let navContent = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
    <head><title>Navigation</title><meta charset="utf-8" /></head>
    <body><nav epub:type="toc" id="toc"><h1>Table of Contents</h1><ol><li><a href="text/page_0001.xhtml">Start Reading</a></li></ol></nav></body>
    </html>
    """

    public static func buildNCXContent(bookUUID: String, baseFilename: String) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head><meta name="dtb:uid" content="urn:uuid:\(bookUUID)"/></head>
            <docTitle><text>\(baseFilename)</text></docTitle>
            <navMap>
                <navPoint id="navPoint-1" playOrder="1">
                    <navLabel><text>Start</text></navLabel>
                    <content src="text/page_0001.xhtml"/>
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
        isManga: Bool
    ) -> String {
        let modified = ISO8601DateFormatter().string(from: Date())
        let coverMeta = (batchIndex > 0 && hasCoverData) ? "cover_reused_img" : "img_1"
        let direction = isManga ? "rtl" : "ltr"
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:epub="http://www.idpf.org/2007/ops" unique-identifier="BookID" version="3.0" prefix="rendition: http://www.idpf.org/vocab/rendition/# dcterms: http://purl.org/dc/terms/">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="BookID">urn:uuid:\(bookUUID)</dc:identifier>
                <dc:title>\(baseFilename.xmlEscaped())</dc:title>
                <dc:language>en</dc:language>
                <meta property="dcterms:modified">\(modified)</meta>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:orientation">auto</meta>
                <meta property="rendition:spread">auto</meta>
                <meta name="fixed-layout" content="true"/>
                <meta name="cover" content="\(coverMeta)"/>
            </metadata>
            <manifest>
                \(manifestItems.joined(separator: "\n        "))
            </manifest>
            <spine toc="ncx" page-progression-direction="\(direction)">
                \(spineItems.joined(separator: "\n        "))
            </spine>
        </package>
        """
    }

    public static func buildChunkXHTML(chunkIndex: Int, images: [String], title: String) -> String {
        let imageElements = images.enumerated().map { _, imageName in
            """
                <div class="page">
                    <img src="../images/\(imageName)" class="page-image" alt="Page Image"/>
                </div>
            """
        }.joined(separator: "\n")
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head>
            <meta charset="UTF-8"/>
            <meta name="viewport" content="width=100vw, height=100vh"/>
            <title>\(title)</title>
            <style>
                @page { margin: 0; padding: 0; }
                @media amzn-kf8 { body { margin: 0 !important; padding: 0 !important; } }
                html, body { margin: 0; padding: 0; background-color: #000000; overflow: hidden; height: 100vh; width: 100vw; }
                .chunk-container { display: flex; justify-content: center; align-items: center; width: 100vw; height: 100vh; margin: 0; padding: 0; }
                .page { display: flex; justify-content: center; align-items: center; width: 100vw; height: 100vh; margin: 0; padding: 0; }
                .page-image { max-width: 100vw; max-height: 100vh; height: 100%; width: 100%; object-fit: contain; object-position: center; }
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

import Foundation

class OPFGenerator {
    static func generateHardenedMetadata(title: String, width: Int? = nil, height: Int? = nil) -> String {
        var resolutionTag = ""
        if let w = width, let h = height {
            resolutionTag = "\n            <meta name=\"original-resolution\" content=\"\(w)x\(h)\"/>"
        }
        
        return """
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:identifier id="pub-id">uuid-\(UUID().uuidString)</dc:identifier>
            <dc:title>\(title.xmlEscaped())</dc:title>
            <dc:language>en</dc:language>
            <meta name="cdetype" content="pdoc"/>\(resolutionTag)
            
            <!-- Kindle 5.19.3 Hardened AWS Server-Side Override Tags -->
            <meta name="fixed-layout" content="true"/>
            <meta name="book-type" content="comic"/>
            <meta name="zero-gutter" content="true"/>
            <meta name="zero-margin" content="true"/>
            <meta name="primary-writing-mode" content="horizontal-rl"/>
            
            <meta property="rendition:layout">pre-paginated</meta>
            <meta property="rendition:spread">auto</meta>
            <meta property="rendition:orientation">auto</meta>
        </metadata>
        """
    }
}

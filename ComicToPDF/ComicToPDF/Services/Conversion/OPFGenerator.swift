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
            <dc:identifier opf:scheme="AMAZON">\(UUID().uuidString.prefix(10).uppercased())</dc:identifier>
            <dc:title>\(title.xmlEscaped())</dc:title>
            <dc:language>en</dc:language>
            <meta name="cdetype" content="pdoc"/>\(resolutionTag)
        </metadata>
        """
    }
}

import Foundation
import ZIPFoundation

/// Parses ComicInfo.xml embedded inside a CBZ/CBR archive.
/// ComicInfo.xml is the industry-standard metadata format for comic archives,
/// defined by the ComicRack schema.
struct ComicInfoParser {

    struct ComicInfo {
        var series: String?
        var title: String?
        var number: String?      // Issue number (can be "1", "1.5", "Annual 2022")
        var volume: Int?
        var writer: String?
        var publisher: String?
        var year: Int?
        var summary: String?
        var manga: Bool = false
        var languageISO: String?
    }

    /// Attempt to read and parse ComicInfo.xml from a CBZ/CBR archive.
    /// Returns `nil` if the archive has no ComicInfo.xml or if parsing fails.
    static func parse(from archiveURL: URL) -> ComicInfo? {
        guard let archive = try? Archive(url: archiveURL, accessMode: .read) else {
            Logger.shared.log("ComicInfoParser: Could not open archive \(archiveURL.lastPathComponent)", category: "Import")
            return nil
        }

        // Search case-insensitively at any path depth
        guard let entry = archive.first(where: { $0.path.lowercased().hasSuffix("comicinfo.xml") }) else {
            return nil // No ComicInfo.xml — normal, not an error
        }

        var xmlData = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                xmlData.append(chunk)
            }
        } catch {
            Logger.shared.log("ComicInfoParser: Failed to extract ComicInfo.xml: \(error.localizedDescription)", category: "Import")
            return nil
        }

        return parseXML(xmlData)
    }

    // MARK: - Private XML Parsing

    private static func parseXML(_ data: Data) -> ComicInfo? {
        let parser = ComicInfoXMLParser(data: data)
        return parser.parse()
    }
}

// MARK: - SAX XML Parser

private class ComicInfoXMLParser: NSObject, XMLParserDelegate {

    private let data: Data
    private var result = ComicInfoParser.ComicInfo()
    private var currentElement = ""
    private var currentText = ""

    init(data: Data) {
        self.data = data
    }

    func parse() -> ComicInfoParser.ComicInfo? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return nil }
        return result.series != nil || result.title != nil ? result : nil
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        switch elementName {
        case "Series":       result.series = value
        case "Title":        result.title = value
        case "Number":       result.number = value
        case "Volume":       result.volume = Int(value)
        case "Writer":       result.writer = value
        case "Publisher":    result.publisher = value
        case "Year":         result.year = Int(value)
        case "Summary":      result.summary = value
        case "LanguageISO":  result.languageISO = value
        case "Manga":        result.manga = value.lowercased() == "yes" || value.lowercased() == "true"
        default: break
        }
        currentText = ""
    }
}

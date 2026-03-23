import Foundation
import ZIPFoundation

/// A deterministic local parser for `ComicInfo.xml` structured metadata.
class LocalComicInfoService {
    static let shared = LocalComicInfoService()
    
    private init() {}
    
    /// Streams `ComicInfo.xml` directly from the archive, parses the necessary tags, and returns the exactly formatted filename string.
    /// Under the Zero-Silence Policy, every failure or warning must be explicitly thrown or logged.
    func generateDeterministicFilename(from cbzURL: URL) throws -> String {
        return try fetchNonDestructiveMetadata(from: cbzURL).displayName
    }
    
    /// Parses the archive non-destructively, returning the calculated UI string alongside the raw internal tags.
    func fetchNonDestructiveMetadata(from cbzURL: URL) throws -> (displayName: String, parsedSeries: String?, parsedNumber: String?, parsedVolume: String?, parsedTitle: String?) {
        guard let archive = try? Archive(url: cbzURL, accessMode: .read, pathEncoding: .utf8) else {
            let errorMsg = "BadZipFile: Could not open archive at \(cbzURL.lastPathComponent)"
            Logger.shared.log(errorMsg, category: "LocalRenamer", type: .error)
            throw NSError(domain: "ZipException", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        let pathExtension = cbzURL.pathExtension.lowercased()
        guard ["cbz", "zip"].contains(pathExtension) else {
            let errorMsg = "ExtractionError: Target file '\(cbzURL.lastPathComponent)' is not a structured ZIP/CBZ."
            Logger.shared.log(errorMsg, category: "LocalRenamer", type: .warning)
            throw NSError(domain: "Format", code: 2, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        // 1. Locate ComicInfo.xml
        guard let entry = archive["ComicInfo.xml"] ?? archive["comicinfo.xml"] else {
            let errorMsg = "MissingMetadataError: No 'ComicInfo.xml' found inside \(cbzURL.lastPathComponent)"
            Logger.shared.log(errorMsg, category: "LocalRenamer", type: .error)
            throw NSError(domain: "MissingMetadata", code: 404, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        // 2. Stream Exact File into Memory
        var xmlData = Data()
        do {
            _ = try archive.extract(entry) { data in
                xmlData.append(data)
            }
        } catch {
            let errorMsg = "ExtractionError: Failed to stream 'ComicInfo.xml' stream from \(cbzURL.lastPathComponent): \(error.localizedDescription)"
            Logger.shared.log(errorMsg, category: "LocalRenamer", type: .error)
            throw NSError(domain: "ZipException", code: 3, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        // 3. Parse Metadata Tags
        let parser = LocalRenamerXMLParser()
        let parserRef = XMLParser(data: xmlData)
        parserRef.delegate = parser
        
        let success = parserRef.parse()
        if !success {
            let parserErr = parserRef.parserError?.localizedDescription ?? "Unknown Parse Error"
            let errorMsg = "CorruptedXMLError: Parser failed on \(cbzURL.lastPathComponent) - \(parserErr)"
            Logger.shared.log(errorMsg, category: "LocalRenamer", type: .error)
            throw NSError(domain: "XMLFormat", code: 4, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        // 4. Construct Formatted String
        let series = parser.series ?? "Unknown Series"
        let titleBlock = parser.title != nil ? " - \(parser.title!)" : ""
        
        var volumeBlock = ""
        if let v = parser.volume {
            volumeBlock = " - v\(v)"
        } else {
            Logger.shared.log("Missing <Volume> tag softly ignored for \(cbzURL.lastPathComponent)", category: "LocalRenamer", type: .warning)
        }
        
        var numberBlock = ""
        if let numRaw = parser.number {
            // Apply 3-digit Zero-Padding natively
            if let intNum = Int(numRaw) {
                numberBlock = String(format: " - c%03d", intNum)
            } else {
                numberBlock = " - c\(numRaw)" // Fallback for fractional issues (e.g. 1.5)
            }
        } else {
            Logger.shared.log("Missing <Number> tag softly ignored for \(cbzURL.lastPathComponent)", category: "LocalRenamer", type: .warning)
        }
        
        var candidateName = "\(series)\(volumeBlock)\(numberBlock)\(titleBlock)"
        
        // Sanitize OS-Reserved Characters
        candidateName = candidateName.replacingOccurrences(of: "/", with: "-")
                                     .replacingOccurrences(of: "\\", with: "-")
                                     .replacingOccurrences(of: ":", with: "-")
                                     .replacingOccurrences(of: "*", with: "")
                                     .replacingOccurrences(of: "?", with: "")
                                     .replacingOccurrences(of: "\"", with: "'")
                                     .replacingOccurrences(of: "<", with: "(")
                                     .replacingOccurrences(of: ">", with: ")")
                                     .replacingOccurrences(of: "|", with: "-")
        
        // Remove Non-printable ASCII/Unicode clutter
        candidateName = candidateName.components(separatedBy: .controlCharacters).joined()
        return (displayName: candidateName.trimmingCharacters(in: .whitespacesAndNewlines), parsedSeries: parser.series, parsedNumber: parser.number, parsedVolume: parser.volume, parsedTitle: parser.title)
    }
}

/// Specialized internal delegate that rips Data fields directly off the streaming XML DOM.
class LocalRenamerXMLParser: NSObject, XMLParserDelegate {
    var series: String?
    var number: String?
    var volume: String?
    var title: String?
    
    private var currentElement: String = ""
    private var currentValue: String = ""
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentValue = ""
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return }
        
        switch elementName {
        case "Series": self.series = value
        case "Number": self.number = value
        case "Volume": self.volume = value
        case "Title": self.title = value
        default: break
        }
        currentElement = ""
        currentValue = ""
    }
}

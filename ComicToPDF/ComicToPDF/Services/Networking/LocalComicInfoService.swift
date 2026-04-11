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
            // SILENT FALLBACK: If XML is missing, extract series and number heuristically from the filename.
            return fallbackFilenameHeuristics(filename: cbzURL.deletingPathExtension().lastPathComponent)
        }
        
        // 2. Stream Exact File into Memory
        var xmlData = Data()
        do {
            _ = try archive.extract(entry) { data in
                xmlData.append(data)
            }
        } catch {
            let errorMsg = "ExtractionError: Failed to stream 'ComicInfo.xml' stream from \(cbzURL.lastPathComponent)"
            Logger.shared.log(errorMsg, category: "LocalRenamer", type: .error)
            throw NSError(domain: "ZipException", code: 3, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        // 3. Parse Metadata Tags
        let parser = LocalRenamerXMLParser()
        let parserRef = XMLParser(data: xmlData)
        parserRef.delegate = parser
        
        let success = parserRef.parse()
        if !success {
            return fallbackFilenameHeuristics(filename: cbzURL.deletingPathExtension().lastPathComponent)
        }
        
        // 4. Construct Formatted String
        let series = parser.series ?? cbzURL.deletingPathExtension().lastPathComponent
        let titleBlock = parser.title != nil ? " - \(parser.title!)" : ""
        
        var volumeBlock = ""
        if let v = parser.volume {
            volumeBlock = " - v\(v)"
        }
        
        var numberBlock = ""
        if let numRaw = parser.number {
            if let intNum = Int(numRaw) {
                numberBlock = String(format: " - c%03d", intNum)
            } else {
                numberBlock = " - c\(numRaw)" 
            }
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
    
    /// Heuristically parses structured conventions (e.g. "SeriesName v01 c045.cbz")
    private func fallbackFilenameHeuristics(filename: String) -> (String, String?, String?, String?, String?) {
        var seriesStr: String? = nil
        var numberStr: String? = nil
        var volumeStr: String? = nil
        
        let cleaned = filename.replacingOccurrences(of: "_", with: " ")
        
        // Match Chapter/Issue conventions at the end of string
        // Eg: "Initial D Chapter 32" or "Dark Web - 001" or "Issue 4.5"
        let pattern = "\\s(?:#|v|vol|ch|chapter|issue)?\\.?\\s*(\\d+\\.?\\d*)[^a-zA-Z]*$"
        if let match = cleaned.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            numberStr = String(cleaned[match]).trimmingCharacters(in: CharacterSet(charactersIn: " #vvolchapteisu.").union(.whitespaces))
            seriesStr = String(cleaned[..<match.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " -_").union(.whitespaces))
        } else {
            seriesStr = cleaned
        }
        
        // Strip reading order prefixes (e.g., "01 Dark Web" -> "Dark Web")
        if var finalSeries = seriesStr {
            let prefixPattern = "^\\d+\\s*[-.]?\\s*"
            if let prefixMatch = finalSeries.range(of: prefixPattern, options: .regularExpression) {
                finalSeries = String(finalSeries[prefixMatch.upperBound...])
            }
            seriesStr = finalSeries.isEmpty ? nil : finalSeries
        }
        
        return (displayName: filename, parsedSeries: seriesStr, parsedNumber: numberStr, parsedVolume: volumeStr, parsedTitle: nil)
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


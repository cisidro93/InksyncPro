import Foundation
import UIKit
import ZIPFoundation

// MARK: - EBook Metadata Model
struct EBookMetadata {
    var title: String = ""
    var author: String = ""
    var publisher: String = ""
    var language: String = ""
    var description: String = ""
    var isbn: String = ""
    var genre: String = ""
    var coverItem: String = ""       // href of the cover image entry
    var spineItems: [SpineItem] = [] // ordered reading list
    
    struct SpineItem: Identifiable {
        let id: String        // manifest id
        let href: String      // path relative to OPF file
        var label: String     // display name (from NCX/nav or derived from href)
    }
}

// MARK: - EBookParser
/// Lightweight, memory-safe EPUB metadata and spine parser.
/// Uses ZIPFoundation streaming to read only OPF and NCX entries — never unzips the full archive.
actor EBookParser {
    
    static let shared = EBookParser()
    
    // MARK: - Public API
    
    /// Parse the spine (reading order) and metadata from an EPUB file.
    /// Returns nil gracefully on any error; all errors are logged.
    func parse(epub url: URL) async -> EBookMetadata? {
        do {
            guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: .utf8) else {
                Logger.shared.log("EBookParser: cannot open archive at \(url.lastPathComponent)", category: "EBook", type: .error)
                return nil
            }
            
            // Step 1: Read META-INF/container.xml to find the OPF path
            guard let opfPath = try readOPFPath(from: archive) else {
                Logger.shared.log("EBookParser: container.xml missing or unparseable in \(url.lastPathComponent)", category: "EBook", type: .error)
                return nil
            }
            
            // Step 2: Parse the OPF document
            guard let opfData = try readEntry(at: opfPath, in: archive) else {
                Logger.shared.log("EBookParser: OPF not found at \(opfPath)", category: "EBook", type: .error)
                return nil
            }
            
            let opfDir = (opfPath as NSString).deletingLastPathComponent
            let metadata = try self.parseOPF(data: opfData, opfDir: opfDir, archive: archive)
            
            Logger.shared.log("EBookParser: parsed \"\(metadata.title)\" — \(metadata.spineItems.count) spine items", category: "EBook")
            return metadata
            
        } catch {
            Logger.shared.log("EBookParser error for \(url.lastPathComponent): \(error.localizedDescription)", category: "EBook", type: .error)
            return nil
        }
    }
    
    /// Extracts only the cover image entry into a UIImage. Memory-safe streaming.
    static func extractCover(from url: URL, href: String) async -> URL? {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: .utf8) else { return nil }
        
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
        let tempFileURL = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension((href as NSString).pathExtension)
        
        do {
            var targetEntry: Entry? = archive[href]
            if targetEntry == nil {
                let lowerHref = href.lowercased()
                for e in archive {
                    if e.path.lowercased().hasSuffix(lowerHref) {
                        targetEntry = e
                        break
                    }
                }
            }
            
            guard let entry = targetEntry else {
                Logger.shared.log("EBookParser: Cover entry not found at \(href) in \(url.lastPathComponent)", category: "EBook", type: .error)
                return nil
            }
            
            _ = try archive.extract(entry, to: tempFileURL)
            return tempFileURL
        } catch {
            Logger.shared.log("EBookParser: Failed to extract cover image from \(url.lastPathComponent) at \(href): \(error.localizedDescription)", category: "EBook", type: .error)
            return nil
        }
    }
    
    // MARK: - Private Helpers
    
    private func readOPFPath(from archive: Archive) throws -> String? {
        guard let entry = findEntry(named: "META-INF/container.xml", in: archive),
              let data = try? readEntry(entry: entry, in: archive) else { return nil }
        return parseContainerXML(data: data)
    }
    
    private func readEntry(at path: String, in archive: Archive) throws -> Data? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let entry = findEntry(named: trimmed, in: archive) else { return nil }
        return try readEntry(entry: entry, in: archive)
    }
    
    private func findEntry(named path: String, in archive: Archive) -> Entry? {
        if let exact = archive[path] { return exact }
        let target = path.lowercased()
        for entry in archive {
            if entry.path.lowercased().hasSuffix(target) { return entry }
        }
        return nil
    }
    
    private func readEntry(entry: Entry, in archive: Archive) throws -> Data? {
        var result = Data()
        _ = try archive.extract(entry) { chunk in result.append(chunk) }
        return result
    }
    
    private func parseContainerXML(data: Data) -> String? {
        let parser = MiniXMLParser(data: data)
        return parser.firstAttributeValue(tag: "rootfile", attribute: "full-path")
    }
    
    private func parseOPF(data: Data, opfDir: String, archive: Archive) throws -> EBookMetadata {
        var metadata = EBookMetadata()
        let parser = MiniXMLParser(data: data)
        
        // Metadata fields
        metadata.title       = parser.firstTextContent(tag: "title") ?? ""
        metadata.author      = parser.firstTextContent(tag: "creator") ?? ""
        metadata.publisher   = parser.firstTextContent(tag: "publisher") ?? ""
        metadata.language    = parser.firstTextContent(tag: "language") ?? ""
        metadata.description = parser.firstTextContent(tag: "description") ?? ""
        
        // ISBN from dc:identifier or identifier
        metadata.isbn = parser.allTextContents(tag: "identifier")
            .first { $0.hasPrefix("urn:isbn:") || $0.hasPrefix("ISBN") } ?? ""
        
        // Cover: look for <meta name="cover" content="itemId">
        if let coverItemId = parser.firstAttributeValue(tag: "meta", attribute: "content",
                                                         where: "name", equals: "cover") {
            // Find the href for that manifest item id
            metadata.coverItem = parser.manifestHref(forId: coverItemId, opfDir: opfDir) ?? ""
        }
        
        // 1. Locate and parse the Table of Contents (TOC) Map
        var tocMap: [String: String] = [:]
        var tocHref = parser.firstAttributeValue(tag: "item", attribute: "href", where: "properties", equals: "nav") // EPUB 3
        if tocHref == nil {
            if let ncxId = parser.firstAttributeValue(tag: "spine", attribute: "toc") { // EPUB 2
                tocHref = parser.manifestHref(forId: ncxId, opfDir: "")
            }
        }
        
        if let href = tocHref {
            let fullTocPath = opfDir.isEmpty ? href : "\(opfDir)/\(href)"
            if let entry = findEntry(named: fullTocPath, in: archive),
               let tocData = try? readEntry(entry: entry, in: archive) {
                let tocParser = TOCParser(data: tocData)
                tocParser.parse()
                tocMap = tocParser.tocMap
            }
        }
        
        // Spine items from <spine> → <itemref idref="...">
        let spineIds = parser.spineItemRefs()
        metadata.spineItems = spineIds.compactMap { idref in
            guard let fullHref = parser.manifestHref(forId: idref, opfDir: opfDir) else { return nil }
            
            // Match the TOC href strictly locally as found in the OPF
            let localHref = parser.manifestHref(forId: idref, opfDir: "") ?? ""
            let baseHref = localHref.components(separatedBy: "#").first ?? localHref
            
            let label = tocMap[baseHref] ?? URL(string: fullHref)?.deletingPathExtension().lastPathComponent
                             .replacingOccurrences(of: "_", with: " ")
                             .capitalized ?? idref
                             
            return EBookMetadata.SpineItem(id: idref, href: fullHref, label: label)
        }
        
        return metadata
    }
}

// MARK: - TOCParser
/// Extracts chapter titles by mapping `href` -> `title` from either an NCX or NAV document.
private class TOCParser: NSObject, XMLParserDelegate {
    private let data: Data
    var tocMap: [String: String] = [:]
    
    private var currentText = ""
    private var currentHref: String?
    
    private var inNavLabel = false
    private var inNav = false
    
    init(data: Data) { self.data = data }
    
    func parse() {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let nodeName = elementName.contains(":") ? String(elementName.split(separator: ":").last ?? "") : elementName
        let lower = nodeName.lowercased()
        
        currentText = ""
        
        if lower == "navmap" || lower == "nav" {
            inNav = true
        } else if lower == "navlabel" {
            inNavLabel = true
        } else if lower == "content", let src = attributes["src"] {
            currentHref = src // EPUB 2 NCX
        } else if lower == "a", let href = attributes["href"] {
            currentHref = href // EPUB 3 NAV
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let nodeName = elementName.contains(":") ? String(elementName.split(separator: ":").last ?? "") : elementName
        let lower = nodeName.lowercased()
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if lower == "navlabel" {
            inNavLabel = false
        } else if lower == "text" && inNavLabel {
            if let href = currentHref, !trimmed.isEmpty {
                let baseHref = href.components(separatedBy: "#").first ?? href
                // Only write the first instance to avoid sub-chapter overwrites
                if tocMap[baseHref] == nil { tocMap[baseHref] = trimmed }
            }
        } else if lower == "a" && inNav {
            if let href = currentHref, !trimmed.isEmpty {
                let baseHref = href.components(separatedBy: "#").first ?? href
                if tocMap[baseHref] == nil { tocMap[baseHref] = trimmed }
            }
        } else if lower == "navmap" || lower == "nav" {
            inNav = false
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
}

// MARK: - MiniXMLParser
/// Zero-dependency XML parser built on Foundation's SAX-style XMLParser.
/// Only reads what we need — no DOM built in memory.
private class MiniXMLParser: NSObject, XMLParserDelegate {
    
    private let data: Data
    private var tagStack: [String] = []
    private var currentText: String = ""
    
    // Collected results
    private var textByTag: [String: [String]] = [:]
    private var attributesByTag: [String: [[String: String]]] = [:]
    private var manifestItems: [(id: String, href: String)] = []
    private var spineRefs: [String] = []
    private var inSpine = false
    
    init(data: Data) { self.data = data }
    
    // MARK: - Query API
    func firstTextContent(tag: String) -> String? { _ = parse(); return textByTag[tag]?.first(where: { !$0.isEmpty }) }
    func allTextContents(tag: String) -> [String] { _ = parse(); return textByTag[tag] ?? [] }
    
    func firstAttributeValue(tag: String, attribute: String) -> String? {
        _ = parse()
        return attributesByTag[tag]?.first.flatMap { $0[attribute] }
    }
    
    func firstAttributeValue(tag: String, attribute: String, where whereAttr: String, equals value: String) -> String? {
        _ = parse()
        return attributesByTag[tag]?.first(where: { $0[whereAttr] == value }).flatMap { $0[attribute] }
    }
    
    func manifestHref(forId id: String, opfDir: String) -> String? {
        _ = parse()
        guard let item = manifestItems.first(where: { $0.id == id }) else { return nil }
        let joined = opfDir.isEmpty ? item.href : "\(opfDir)/\(item.href)"
        return joined
    }
    
    func spineItemRefs() -> [String] {
        _ = parse(); return spineRefs
    }
    
    // MARK: - Lazy Parse
    @discardableResult
    private func parse() -> Bool {
        if !textByTag.isEmpty || !attributesByTag.isEmpty || !manifestItems.isEmpty { return true }
        let p = XMLParser(data: data)
        p.delegate = self
        return p.parse()
    }
    
    // MARK: - XMLParserDelegate
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let nodeName = elementName.contains(":") ? String(elementName.split(separator: ":").last ?? "") : elementName
        tagStack.append(nodeName)
        currentText = ""
        
        // Accumulate all attribute dictionaries per tag name (lowercased)
        let lower = nodeName.lowercased()
        attributesByTag[lower, default: []].append(attributes)
        
        // Capture manifest items
        if lower == "item", let id = attributes["id"], let href = attributes["href"] {
            manifestItems.append((id: id, href: href))
        }
        
        // Detect spine scope
        if lower == "spine" { inSpine = true }
        
        // Capture spine itemrefs
        if inSpine && lower == "itemref", let idref = attributes["idref"] {
            spineRefs.append(idref)
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let nodeName = elementName.contains(":") ? String(elementName.split(separator: ":").last ?? "") : elementName
        let lower = nodeName.lowercased()
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            textByTag[lower, default: []].append(trimmed)
        }
        if lower == "spine" { inSpine = false }
        tagStack.removeLast()
        currentText = ""
    }
}

import Foundation
import ZIPFoundation
import UIKit

// NOTE: I/O runs on the caller's context (typically a Task).
// Only UI status string updates are dispatched to @MainActor.
final class SmartPanelService: Sendable {
    static let shared = SmartPanelService()
    
    // Internal Sidecar Model
    struct SmartPanel: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    func extractSmartPanels(from url: URL) async throws -> [Int: [PanelExtractor.Panel]]? {
        await MainActor.run { TaskEngine.shared.processingStatus = "Reading Source Panels..." }
        
        Logger.shared.log("Inspection Started: \(url.lastPathComponent)", category: "SmartPanels")
        
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: .utf8) else {
            throw ConversionError.invalidFormat
        }
        
        // 1. Check OPF Embedded Metadata
        if let opfEntry = archive.makeIterator().first(where: { $0.path.hasSuffix(".opf") }) {
            var opfData = Data()
            if let _ = try? archive.extract(opfEntry, consumer: { opfData.append($0) }),
               let opfString = String(data: opfData, encoding: .utf8) {
                
                if let range = opfString.range(of: "name=\"inksync-comicinfo\""),
                   let suffix = Optional(opfString[range.upperBound...]),
                   let contentStart = suffix.range(of: "content=\""),
                   let contentSuffix = Optional(suffix[contentStart.upperBound...]),
                   let contentEnd = contentSuffix.range(of: "\"") {
                       
                    let base64 = String(contentSuffix[..<contentEnd.lowerBound])
                    if let xmlData = Data(base64Encoded: base64) {
                        Logger.shared.log("Found Embedded ComicInfo in OPF", category: "SmartPanels")
                        let parser = ComicInfoPanelParser(data: xmlData)
                        let result = parser.parse()
                        if !result.isEmpty {
                            await MainActor.run { TaskEngine.shared.processingStatus = "Metadata Found (Embedded)" }
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            return result
                        }
                    }
                }
            }
        }
        
        // 2. Physical File Fallback
        var comicInfoEntry: Archive.Element? = nil
        if let entry = archive["META-INF/ComicInfo.xml"] {
            comicInfoEntry = entry
        } else if let entry = archive["ComicInfo.xml"] {
             comicInfoEntry = entry
        } else {
             comicInfoEntry = archive.makeIterator().first { $0.path.lowercased().hasSuffix("comicinfo.xml") }
        }
        
        // 3. Legacy JSON Fallback
        if comicInfoEntry == nil, let jsonEntry = archive["panels.json"] ?? archive.makeIterator().first(where: { $0.path.lowercased().hasSuffix("panels.json") }) {
            var jsonData = Data()
            do {
                _ = try archive.extract(jsonEntry) { jsonData.append($0) }
                let decoded = try JSONDecoder().decode([Int: [PanelExtractor.Panel]].self, from: jsonData)
                if !decoded.isEmpty {
                    await MainActor.run { TaskEngine.shared.processingStatus = "Metadata Found (panels.json)" }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    return decoded
                }
            } catch {
                Logger.shared.log("Failed to parse legacy panels.json: \(error)", category: "SmartPanels", type: .error)
            }
        }
        
        guard let entry = comicInfoEntry else {
            Logger.shared.log("No ComicInfo or panels.json Metadata found", category: "SmartPanels")
            await MainActor.run { TaskEngine.shared.processingStatus = "Skipping: No Metadata Found" }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return nil
        }
        
        var xmlData = Data()
        do {
            _ = try archive.extract(entry) { xmlData.append($0) }
        } catch {
            return nil
        }
        
        let parser = ComicInfoPanelParser(data: xmlData)
        var result = parser.parse()
        
        if result.isEmpty {
             await MainActor.run { TaskEngine.shared.processingStatus = "Skipping: Metadata Empty" }
             try? await Task.sleep(nanoseconds: 1_000_000_000)
             return nil
        }
        
        let pageCount = result.count
        await MainActor.run { TaskEngine.shared.processingStatus = "Metadata Found (\(pageCount) pages)" }
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        // Denormalized Repair
        let needsRepair = result.values.flatMap { $0 }.contains { panel in
            return panel.boundingBox.minX > 2.0 || panel.boundingBox.minY > 2.0 || panel.boundingBox.width > 2.0
        }
        
        if needsRepair {
             await MainActor.run { TaskEngine.shared.processingStatus = "Repairing Pixel Coordinates..." }
            
            let sortedEntries = archive.makeIterator().sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let imageEntries = sortedEntries.filter { entry in
                let ext = (entry.path as NSString).pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "webp"].contains(ext) && !entry.path.contains("__MACOSX") && !entry.path.hasPrefix(".")
            }
            
            for (pageIndex, panels) in result {
                guard pageIndex < imageEntries.count else { continue }
                let pageHasPixels = panels.contains { $0.boundingBox.minX > 2.0 || $0.boundingBox.width > 2.0 }
                
                if pageHasPixels {
                    let entry = imageEntries[pageIndex]
                    var imageData = Data()
                    do {
                        _ = try archive.extract(entry) { imageData.append($0) }
                        if let image = UIImage(data: imageData) {
                            let size = image.size
                            if size.width > 0 && size.height > 0 {
                                let normalizedPanels = panels.map { panel -> PanelExtractor.Panel in
                                    let r = panel.boundingBox
                                    let nx = (r.minX > 2.0) ? r.minX / size.width : r.minX
                                    let ny = (r.minY > 2.0) ? r.minY / size.height : r.minY
                                    let nw = (r.width > 2.0) ? r.width / size.width : r.width
                                    let nh = (r.height > 2.0) ? r.height / size.height : r.height
                                    return PanelExtractor.Panel(boundingBox: CGRect(x: nx, y: ny, width: nw, height: nh))
                                }
                                result[pageIndex] = normalizedPanels
                                Logger.shared.log("Repaired Page \(pageIndex) using size \(size)", category: "SmartPanels")
                            }
                        }
                    } catch {}
                }
            }
        }
        
        return result.isEmpty ? nil : result
    }
}

// MARK: - XML Parser
class ComicInfoPanelParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var result: [Int: [PanelExtractor.Panel]] = [:]
    
    private var currentPageIndex: Int?
    private var currentImageSize: CGSize? 
    private var currentPanels: [PanelExtractor.Panel] = []
    
    init(data: Data) {
        self.data = data
        super.init()
    }
    
    func parse() -> [Int: [PanelExtractor.Panel]] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return result
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let cleanName = elementName.components(separatedBy: ":").last ?? elementName
        
        func getAttr(_ key: String) -> String? {
            return attributeDict.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        }
        
        if cleanName.caseInsensitiveCompare("Page") == .orderedSame {
            if let imageStr = getAttr("Image"), let index = Int(imageStr) {
                currentPageIndex = index
                currentPanels = []
                
                if let wStr = getAttr("ImageWidth"), let w = Double(wStr),
                   let hStr = getAttr("ImageHeight"), let h = Double(hStr), w > 0, h > 0 {
                    currentImageSize = CGSize(width: w, height: h)
                } else {
                    currentImageSize = nil
                }
            }
        } else if cleanName.caseInsensitiveCompare("Panel") == .orderedSame {
            if let xVal = getAttr("x"), let x = Double(xVal),
               let yVal = getAttr("y"), let y = Double(yVal),
               let wVal = getAttr("width"), let w = Double(wVal),
               let hVal = getAttr("height"), let h = Double(hVal) {
                
                var rect = CGRect(x: x, y: y, width: w, height: h)
                let isPixels = x > 2.0 || y > 2.0 || w > 2.0 || h > 2.0
                
                if isPixels, let size = currentImageSize {
                    rect = CGRect(
                        x: x / size.width,
                        y: y / size.height,
                        width: w / size.width,
                        height: h / size.height
                    )
                }
                
                let panel = PanelExtractor.Panel(boundingBox: rect)
                currentPanels.append(panel)
            }
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let cleanName = elementName.components(separatedBy: ":").last ?? elementName
        if cleanName.caseInsensitiveCompare("Page") == .orderedSame {
            if let index = currentPageIndex, !currentPanels.isEmpty {
                result[index] = currentPanels
            }
            currentPageIndex = nil
            currentImageSize = nil
            currentPanels = []
        }
    }
}

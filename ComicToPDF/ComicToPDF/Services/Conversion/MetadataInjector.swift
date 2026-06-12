import Foundation
import UIKit
import ZIPFoundation

/// Safely manipulates EPUB/CBZ Open Packaging Format (OPF) data to inject Manga metadata, Amazon ASINs, and structural page properties.
final class MetadataInjector: Sendable {
    static let shared = MetadataInjector()
    private init() {}
    
    // Will hold the extracted methods from ConversionManager
    // Helper to generate the <Pages> block
    private func generatePagesXML(from panelsDict: [String: [ConversionManager.SmartPanel]]) -> String {
        var xml = "  <Pages>\n"
        
        // Sort keys
        let sortedKeys = panelsDict.keys.compactMap { Int($0) }.sorted().map { String($0) }
        
        for key in sortedKeys {
            if let panels = panelsDict[key] {
                // ComicInfo uses Image="0" for the first page
                xml += "    <Page Image=\"\(key)\">\n"
                
                // There is no standard <Panels> tag in ComicInfo, so we use a custom <SmartPanels>
                // Or we can try to use standard schema attributes if possible, but detection has multiple panels per page.
                // We'll use a custom block inside Page.
                xml += "      <SmartPanels>\n"
                for panel in panels {
                    xml += "        <Panel x=\"\(panel.x)\" y=\"\(panel.y)\" width=\"\(panel.width)\" height=\"\(panel.height)\" />\n"
                }
                xml += "      </SmartPanels>\n"
                xml += "    </Page>\n"
            }
        }
        
        xml += "  </Pages>"
        return xml
    }
    
    // ✅ NEW: Embed currently saved panels into the source file (EPUB/CBZ)
    // ✅ NEW: Embed currently saved panels into the source file (EPUB/CBZ)
    func embedPanels(for pdf: ConvertedPDF, manager: ConversionManager) async {
        do {
            let panels = await MainActor.run { PageModelStore.shared.getAllLegacyVisionPanels(for: pdf.id) }
            guard !panels.isEmpty else {
                await MainActor.run {
                    manager.appAlert = AppAlert(title: "No Edits Found", message: "There are no saved panel edits for this file to embed.")
                }
                return
            }
            
            try await injectMetadata(into: pdf.url, panels: panels, metadata: pdf.metadata, manager: manager)
            
            await MainActor.run {
                manager.appAlert = AppAlert(title: "Success", message: "Panels extracted from the database have been successfully embedded into '\(pdf.name)'.")
            }
        } catch {
            await MainActor.run {
                manager.appAlert = AppAlert(title: "Embed Failed", message: error.localizedDescription)
            }
        }
    }
    
    // ✅ NEW: Reusable Metadata Injection with Strict Re-Zip
    func injectMetadata(into archiveURL: URL, panels: [Int: [PanelExtractor.Panel]], metadata: PDFMetadata, manager: ConversionManager) async throws {
        Logger.shared.log("Starting Injection: \(archiveURL.lastPathComponent) with \(panels.count) pages", category: "Injection")
        
        // ---------------------------------------------------------
        // PHASE 1: PREPARE DATA (In Memory)
        // ---------------------------------------------------------
        
        // 1. Generate ComicInfo.xml
        var smartPanelsDict: [String: [ConversionManager.SmartPanel]] = [:]
        for (index, pagePanels) in panels {
            let smartPanels = pagePanels.map { ConversionManager.SmartPanel(x: $0.boundingBox.minX, y: $0.boundingBox.minY, width: $0.boundingBox.width, height: $0.boundingBox.height) }
            smartPanelsDict["\(index)"] = smartPanels
        }
        
        var xmlContent = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xmlContent += "<ComicInfo>\n"
        xmlContent += "  <Title>\(metadata.title.xmlEscaped())</Title>\n"
        if let series = metadata.series { xmlContent += "  <Series>\(series.xmlEscaped())</Series>\n" }
        xmlContent += generatePagesXML(from: smartPanelsDict)
        xmlContent += "\n</ComicInfo>"
        
        guard let comicInfoData = xmlContent.data(using: .utf8) else { return }
        
        // 2. Prepare Updates (OPF & XHTML)
        let fileManager = FileManager.default
        var opfData: Data? = nil
        var opfPath: String? = nil
        var xhtmlUpdates: [String: Data] = [:]
        
        // We need to read the OLD archive first to prepare these updates
        // We scope this so we close the file handle before writing the new one (Windows safe)
        do {
            guard let sourceArchive = try? Archive(url: archiveURL, accessMode: .read, pathEncoding: .utf8) else { return }
            
            // A. Prepare OPF Update
            if let entry = sourceArchive.makeIterator().first(where: { $0.path.hasSuffix(".opf") }) {
                opfPath = entry.path
                var rawOpf = Data()
                _ = try sourceArchive.extract(entry) { rawOpf.append($0) }
                
                if var opfString = String(data: rawOpf, encoding: .utf8) {
                    var modified = false
                    
                    // 1. Kindle ASIN/UUID (Required for Guided View)
                    if !opfString.contains("urn:amazon:asin") && !opfString.contains("urn:uuid:") {
                        if let range = opfString.range(of: "<metadata"),
                           let endOfOpen = opfString[range.upperBound...].range(of: ">") {
                             let insertIndex = endOfOpen.upperBound
                             // Use a consistent ID or new one? New one is fine for export.
                             let asinUUID = UUID().uuidString
                             let tag = "\n    <dc:identifier id=\"uid\">urn:uuid:\(asinUUID)</dc:identifier>"
                             opfString.insert(contentsOf: tag, at: insertIndex)
                             modified = true
                        }
                    }
                    
                    // 1b. Ensure 'rendition' AND 'dcterms' prefixes are declared in <package>
                    // If we use rendition:layout or dcterms:modified, the prefixes must be defined in the root element.
                    if !opfString.contains("http://www.idpf.org/vocab/rendition/#") || !opfString.contains("http://purl.org/dc/terms/") {
                        if let range = opfString.range(of: "<package") {
                            if let endOfOpen = opfString[range.upperBound...].range(of: ">") {
                                // We need to check if 'prefix' attribute already exists
                                let tagContent = opfString[range.upperBound..<endOfOpen.lowerBound]
                                
                                if tagContent.contains("prefix=\"") {
                                    // Append to existing prefix attribute
                                    if let prefixRange = opfString.range(of: "prefix=\"") {
                                        let insertionPoint = prefixRange.upperBound
                                        var newPrefixes = ""
                                        if !opfString.contains("http://www.idpf.org/vocab/rendition/#") {
                                            newPrefixes += "rendition: http://www.idpf.org/vocab/rendition/# "
                                        }
                                        if !opfString.contains("http://purl.org/dc/terms/") {
                                            newPrefixes += "dcterms: http://purl.org/dc/terms/ "
                                        }
                                        opfString.insert(contentsOf: newPrefixes, at: insertionPoint)
                                        modified = true
                                    }
                                } else {
                                    // Insert new prefix attribute
                                    let prefixDef = " prefix=\"rendition: http://www.idpf.org/vocab/rendition/# dcterms: http://purl.org/dc/terms/\""
                                    opfString.insert(contentsOf: prefixDef, at: endOfOpen.lowerBound)
                                    modified = true
                                }
                            }
                        }
                    }
                    
                    // 2. Hardware Clamping Removal
                    // We intentionally NO LONGER inject a hard-coded original-resolution based on physical image pixel dimensions.
                    // Doing so forces the Kindle Scribe's proprietary renderer to hardware clamp its output canvas to those
                    // exact dimensions, completely breaking dynamic 100vw/100vh SVG scaling and introducing Death Margins.
                    
                    // 3. Embed ComicInfo as Base64 (Zero Footprint)
                    // Kindle rejects valid XML files if they aren't in the Manifest, and rejects them IN the manifest if they aren't core types.
                    // Solution: Embed as Base64 metadata in OPF.
                    
                    let base64 = comicInfoData.base64EncodedString()
                    
                    // A. Remove existing tag if present (prevent duplication)
                    // We remove both 'property' (legacy/error) and 'name' (correct) versions to ensure a clean state
                    let pattern = "<meta (property=\"inksync:comicinfo\"|name=\"inksync-comicinfo\")[^>]*>.*?</meta>\\s*|<meta name=\"inksync-comicinfo\" content=\".*?\"/>\\s*"
                    let originalOPF = opfString
                    if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                        let range = NSRange(opfString.startIndex..<opfString.endIndex, in: opfString)
                        opfString = regex.stringByReplacingMatches(in: opfString, options: [], range: range, withTemplate: "")
                        if opfString != originalOPF {
                            modified = true
                            Logger.shared.log("Removed legacy inksync-comicinfo tag", category: "Injection")
                        }
                    }
                    
                    // B. Insert New Tag (CONDITIONAL - Only for Guided View)
                    let settings = await MainActor.run { AppSettingsManager.shared.conversionSettings }
                    if settings.isGuidedView {
                        if let range = opfString.range(of: "</metadata>") {
                             let metaTag = "\n    <meta name=\"inksync-comicinfo\" content=\"\(base64)\"/>"
                             opfString.insert(contentsOf: metaTag, at: range.lowerBound)
                             modified = true
                             Logger.shared.log("Injected inksync-comicinfo metadata (Guided View)", category: "Injection")
                        }
                    } else {
                        Logger.shared.log("Skipping metadata injection (Standard Mode)", category: "Injection")
                    } 
                    
                    if modified {
                        opfData = opfString.data(using: .utf8)
                    } else {
                        opfData = rawOpf // No changes needed
                    }
                }
            }
            
            // B. Prepare XHTML Updates (EPUB Only)
            if archiveURL.pathExtension.lowercased() == "epub" {
                for (index, _) in panels {
                     let pageNum = index + 1
                     
                     // Try to find image
                     let imageBase = String(format: "image_%04d", pageNum)
                     var imageName: String? = nil
                     var entryPath: String? = nil
                     
                     for ext in ["jpg", "jpeg", "png", "webp"] {
                         let p = "OEBPS/images/\(imageBase).\(ext)"
                         if sourceArchive[p] != nil {
                             imageName = "\(imageBase).\(ext)"
                             entryPath = p
                             break
                         }
                     }
                     
                     if let img = imageName, let path = entryPath, let entry = sourceArchive[path] {
                         var imgData = Data()
                         _ = try sourceArchive.extract(entry) { imgData.append($0) }
                         
                         var w = 1000
                         var h = 1500
                         if let sz = UIImage(data: imgData)?.size {
                             w = Int(sz.width)
                             h = Int(sz.height)
                         }
                         
                         let xhtmlContent = CBZToEPUBConverter.generateChunkXHTML(
                            chunkIndex: pageNum,
                            images: [img],
                            title: "Page \(pageNum)",
                            width: w,
                            height: h
                         )
                         
                         if let data = xhtmlContent.data(using: .utf8) {
                             let savePath = String(format: "OEBPS/text/page_%04d.xhtml", pageNum)
                             xhtmlUpdates[savePath] = data
                         }
                     }
                }
            }
        } catch { Logger.shared.log("Failed to prepare updates: \(error)", category: "Injection") }
        
        // ---------------------------------------------------------
        // PHASE 2: STRICT RE-ZIP (Write New File)
        // ---------------------------------------------------------
        
        let tempID = UUID().uuidString
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(tempID)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        
        let newArchiveURL = tempDir.appendingPathComponent("temp.epub")
        
        // Scope to ensure archive closes (deinit) before move
        do {
            guard let newArchive = try? Archive(url: newArchiveURL, accessMode: .create, pathEncoding: .utf8) else {
                Logger.shared.log("Failed to create temporary archive", category: "Injection")
                return 
            }
            
            // 1. MIMETYPE (Must be First & Stored & NO EXTRA FIELDS)
            // Writing to disk and adding as file avoids explicit metadata passed in the closure-based API
            // which likely triggers ZIPFoundation to write extended timestamps.
            let mimePath = tempDir.appendingPathComponent("mimetype")
            try "application/epub+zip".write(to: mimePath, atomically: true, encoding: .ascii)
            
            try newArchive.addEntry(with: "mimetype", fileURL: mimePath, compressionMethod: .none)
            try? fileManager.removeItem(at: mimePath)
            
            // 2. META-INF/container.xml (Must be Second for strict compliance)
            var processedPaths: Set<String> = ["mimetype"]
            
            if let oldArchive = try? Archive(url: archiveURL, accessMode: .read, pathEncoding: .utf8) {
                if let containerEntry = oldArchive["META-INF/container.xml"] {
                    let tempContainer = tempDir.appendingPathComponent("container.xml")
                    _ = try oldArchive.extract(containerEntry, to: tempContainer)
                    try newArchive.addEntry(with: "META-INF/container.xml", fileURL: tempContainer, compressionMethod: .deflate)
                    try? fileManager.removeItem(at: tempContainer)
                    processedPaths.insert("META-INF/container.xml")
                }
            
                // 3. MIGRATE REMAINDER (Copy from Old -> New)
                for entry in oldArchive {
                    if processedPaths.contains(entry.path) { continue }
                    
                    // Skip Special Files (We inject/update these manually)
                    // We need to calculate comicInfoPath here too or just skip strictly by suffix if we want to be safe?
                    // Safe approach: Skip if it ends in ComicInfo.xml AND is in the same dir as OPF.
                    // But simpler: We calculated `opfPath` earlier.
                    
                    let targetComicInfoPath: String
                    if let opf = opfPath, let lastSlash = opf.lastIndex(of: "/") {
                         let dir = opf[..<lastSlash]
                         targetComicInfoPath = "\(dir)/ComicInfo.xml"
                    } else {
                         targetComicInfoPath = "ComicInfo.xml"
                    }
                    
                    if entry.path == targetComicInfoPath { continue }
                    if entry.path == "ComicInfo.xml" { continue } 
                    if entry.path == "META-INF/ComicInfo.xml" { continue } // ✅ Skip new location too
                    if entry.path == opfPath { continue }
                    if xhtmlUpdates.keys.contains(entry.path) { continue }
                    
                    // Each entry needs its own uniquely-named temp file.
                    // Reusing "transfer.tmp" means entry N's file gets overwritten by
                    // entry N+1 before ZIPFoundation's addEntry closure finishes reading it,
                    // corrupting the output and potentially crashing with a CRC mismatch.
                    let tempExtract = tempDir.appendingPathComponent(UUID().uuidString + ".tmp")
                    _ = try oldArchive.extract(entry, to: tempExtract)
                    defer { try? fileManager.removeItem(at: tempExtract) }

                    try newArchive.addEntry(with: entry.path, fileURL: tempExtract, compressionMethod: .deflate)
                }
            }
            
            // 4. INJECT NEW/UPDATED FILES
            
            // ComicInfo check: Ensure it lives next to OPF
            // ComicInfo check: Ensure it lives in META-INF (Best Practice for ignoring files in Manifest)
            // If it was in OEBPS, we arguably should MOVE it, but for now let's just write to META-INF if that's where we target.
            
            // ComicInfo File Injection (REMOVED)
            // We now embed this in the OPF metadata above.
            // keeping this comment for context.
            // let comicInfoPath = "META-INF/ComicInfo.xml"
            // try newArchive.addEntry(...)
            
            // OPF
            if let data = opfData, let path = opfPath {
                // Log OPF for debugging
                if String(data: data, encoding: .utf8) != nil {

                }
                
                try newArchive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), modificationDate: Date(), permissions: 0o644, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { pos, size in
                    return data.subdata(in: Int(pos)..<min(Int(pos)+size, data.count))
                }
            }
            
            // XHTML Updates
            for (path, data) in xhtmlUpdates {
                try newArchive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), modificationDate: Date(), permissions: 0o644, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { pos, size in
                    return data.subdata(in: Int(pos)..<min(Int(pos)+size, data.count))
                }
            }
            
        } // DEINIT: newArchive closed here
        
        // 5. ATOMIC SWAP
        try finalizeSwap(source: newArchiveURL, dest: archiveURL)
        Logger.shared.log("Successfully rebuilt EPUB structure", category: "Injection")
        
        // 6. LOG STRUCTURE (Flight Recorder)
        Logger.shared.logEPUBStructure(at: archiveURL)
    }
    

    
    // Helper to finish the swap (Split out to ensure deinit)
    private func finalizeSwap(source: URL, dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: source, to: dest)
    }
    
    // MARK: - Kindle OPF Injection
    // Ensures ASIN and Fixed-Layout Metadata exist for Guided View support.
    private func ensureKindleOPF(at url: URL) async throws {
        // Re-implements the Hot-Fix logic to ensure ASIN and Fixed-Layout tags exist in the OPF.
        // This is critical for activating Guided View on Kindle devices.
        
        let fileManager = FileManager.default
        _ = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        // Optimize: We don't need to unzip everything, just the OPF. 
        // But ZIPFoundation update requires re-archiving or careful manipulation.
        // Simplest consistent way: Read Entry -> Modify -> Remove -> Add.
        
        guard let archive = try? Archive(url: url, accessMode: .update, pathEncoding: .utf8) else { return }
        
        // Find OPF
        guard let opfEntry = archive.makeIterator().first(where: { $0.path.hasSuffix(".opf") }) else { return }
        let opfPath = opfEntry.path
        
        var opfData = Data()
        _ = try archive.extract(opfEntry) { data in opfData.append(data) }
        
        guard var opfString = String(data: opfData, encoding: .utf8) else { return }
        var modified = false
        
        // 1. Check ASIN / UUID
        // Kindle treats 'urn:uuid:...' in dc:identifier as valid for layout activation
        if !opfString.contains("urn:amazon:asin") && !opfString.contains("urn:uuid:") {
            if let range = opfString.range(of: "<metadata") {
                if let endOfOpen = opfString[range.upperBound...].range(of: ">") {
                     let insertIndex = endOfOpen.upperBound
                     let asinUUID = UUID().uuidString
                     let tag = "\n    <dc:identifier id=\"uid\">urn:uuid:\(asinUUID)</dc:identifier>"
                     opfString.insert(contentsOf: tag, at: insertIndex)
                     modified = true
                }
            }
        }
        
        // 2. Check Fixed Layout
        if !opfString.contains("rendition:layout") {
             if let range = opfString.range(of: "</metadata>") {
                 let tag = "\n    <meta property=\"rendition:layout\">pre-paginated</meta>\n    <meta property=\"rendition:orientation\">auto</meta>\n    <meta property=\"rendition:spread\">auto</meta>\n    <meta name=\"fixed-layout\" content=\"true\"/>"
                 opfString.insert(contentsOf: tag, at: range.lowerBound)
                 modified = true
             }
        }
        
        if modified {
            if let newData = opfString.data(using: .utf8) {
                try archive.remove(opfEntry)
                try archive.addEntry(with: opfPath, type: .file, uncompressedSize: Int64(newData.count), modificationDate: Date(), permissions: 0o644, compressionMethod: .deflate, bufferSize: 8192, progress: nil) { position, size in
                     return newData.subdata(in: Int(position)..<min(Int(position)+size, newData.count))
                }
            }
        }
    }
}

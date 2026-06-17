import Foundation
import SwiftData

@MainActor
class MigrationService {
    static let shared = MigrationService()
    
    private func getLibraryURL() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("library_v3.json")
    }
    
    private func getCollectionsURL() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("collections_v2.json")
    }
    
    func migrateLegacyDataIfNeeded(context: ModelContext) {
        // Only run migration once
        if UserDefaults.standard.bool(forKey: "hasMigratedToSwiftData_v1") { return }
        
        let libraryURL = getLibraryURL()
        guard let data = try? Data(contentsOf: libraryURL),
              let legacyPDFs = try? JSONDecoder().decode([ConvertedPDF].self, from: data) else {
            // No legacy data found, fast forward
            UserDefaults.standard.set(true, forKey: "hasMigratedToSwiftData_v1")
            return
        }
        
        // Parse legacy collections
        let collectionsURL = getCollectionsURL()
        var legacyCollections: [PDFCollection] = []
        if let cData = try? Data(contentsOf: collectionsURL),
           let cols = try? JSONDecoder().decode([PDFCollection].self, from: cData) {
            legacyCollections = cols
        }
        
        var containerMap: [UUID: SDPDFCollection] = [:]
        
        // 1. Insert Containers
        for col in legacyCollections {
            let container = SDPDFCollection(id: col.id, name: col.name, icon: col.icon, color: col.color, creationDate: col.creationDate, explicitCoverFileID: col.explicitCoverFileID)
            context.insert(container)
            containerMap[col.id] = container
        }
        
        // 2. Insert Documents and Relate
        for pdf in legacyPDFs {
            let doc = SDConvertedPDF(id: pdf.id, name: pdf.name, url: pdf.url, pageCount: pdf.pageCount, fileSize: pdf.fileSize, metadata: pdf.metadata, collectionId: pdf.collectionId, isFavorite: pdf.isFavorite, isPrivate: pdf.isPrivate, coverImageData: pdf.coverImageData, contentType: pdf.contentType, chapters: pdf.chapters, addedByMode: pdf.addedByMode, sourceMode: pdf.sourceMode)
            
            // Re-establish relationships natively in SwiftData
            if let colId = pdf.collectionId, containerMap[colId] != nil {
                // the document already has collectionId set in init
            }
            context.insert(doc)
        }
        
        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: "hasMigratedToSwiftData_v1")
            Logger.shared.log("Successfully migrated \(legacyPDFs.count) books and \(legacyCollections.count) collections to SwiftData", category: "Migration")
            
            // 🔥 Nuke the legacy JSON ghost files from iCloud Drive / Documents directory permanently.
            // If we leave them, uninstalling and reinstalling the app will cause iCloud Drive to 
            // restore these files, and the app will silently reconstruct the old history!
            try? FileManager.default.removeItem(at: libraryURL)
            let collectionsURL = getCollectionsURL()
            try? FileManager.default.removeItem(at: collectionsURL)
            
        } catch {
            Logger.shared.log("Fatal Error during SwiftData migration: \(error.localizedDescription)", category: "Migration", type: .error)
        }
    }
    
    // ✅ Smart Regex Grouping Algorithm
    // Automatically takes an array of unassigned documents and creates InkContainers 
    // for series matching known syntax (e.g. "Batman Vol. 1", "Batman Vol. 2")
    func performSmartGrouping(context: ModelContext) -> Int {
        return Self.performSmartGroupingInternal(context: context)
    }

    nonisolated static func performSmartGroupingInternal(context: ModelContext) -> Int {
        // Fetch all documents and filter in memory to dodge `#Predicate` translation limitations on optional arrays
        let fetchDescriptor = FetchDescriptor<SDConvertedPDF>()
        guard let allDocs = try? context.fetch(fetchDescriptor) else { return 0 }
        
        // Fetch all collections to do case-insensitive lookup and find existing IDs
        let colsDescriptor = FetchDescriptor<SDPDFCollection>()
        guard let existingCols = try? context.fetch(colsDescriptor) else { return 0 }
        let existingColIDs = Set(existingCols.map { $0.id })
        
        let orphans = allDocs.filter { doc in
            guard let cid = doc.collectionId else { return true }
            return !existingColIDs.contains(cid)
        }
        
        struct GroupInfo {
            let displayName: String
            var docs: [SDConvertedPDF]
        }
        var groupedByName: [String: GroupInfo] = [:] // key: normalized (lowercased) series name
        
        for doc in orphans {
            let rawSeriesName = (doc.metadata.series?.isEmpty == false) ? doc.metadata.series! : MetadataHeuristics.cleanFilename(doc.name)
            let seriesName = SeriesNameParser.cleanFolderName(rawSeriesName).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seriesName.isEmpty else { continue }
            
            let normalizedKey = seriesName.lowercased()
            if var info = groupedByName[normalizedKey] {
                info.docs.append(doc)
                groupedByName[normalizedKey] = info
            } else {
                groupedByName[normalizedKey] = GroupInfo(displayName: seriesName, docs: [doc])
            }
        }
        
        // Map lowercase name to collection object
        var colMap: [String: SDPDFCollection] = [:]
        for col in existingCols {
            let key = col.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                colMap[key] = col
            }
        }
        
        var generatedCount = 0
        var assignedCount = 0
        
        for (normalizedKey, groupInfo) in groupedByName {
            let docs = groupInfo.docs
            let displayName = groupInfo.displayName
            
            let existingContainer = colMap[normalizedKey]
            
            // Group if:
            // 1. A collection with this name already exists.
            // 2. OR, there are at least 2 matching items.
            if existingContainer != nil || docs.count > 1 {
                let container = existingContainer ?? SDPDFCollection(
                    id: UUID(),
                    name: displayName,
                    icon: "folder",
                    color: "blue",
                    creationDate: Date(),
                    explicitCoverFileID: nil
                )
                
                if existingContainer == nil {
                    context.insert(container)
                    colMap[normalizedKey] = container // prevent duplicates in the same loop
                    generatedCount += 1
                }
                
                for doc in docs {
                    if doc.collectionId != container.id {
                        doc.collectionId = container.id
                        doc.metadata.series = container.name
                        assignedCount += 1
                    }
                }
            }
        }
        
        if generatedCount > 0 || assignedCount > 0 {
            try? context.save()
            Logger.shared.log("Smart Grouping generated \(generatedCount) new collections and assigned \(assignedCount) items.", category: "Library")
        }
        
        return generatedCount + assignedCount
    }
}

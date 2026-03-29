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
            let doc = SDConvertedPDF(id: pdf.id, name: pdf.name, url: pdf.url, pageCount: pdf.pageCount, fileSize: pdf.fileSize, metadata: pdf.metadata, collectionId: pdf.collectionId, isFavorite: pdf.isFavorite, isPrivate: pdf.isPrivate, coverImageData: pdf.coverImageData, contentType: pdf.contentType, chapters: pdf.chapters, addedByMode: pdf.addedByMode)
            
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
        } catch {
            Logger.shared.log("Fatal Error during SwiftData migration: \(error.localizedDescription)", category: "Migration", type: .error)
        }
    }
    
    // ✅ Smart Regex Grouping Algorithm
    // Automatically takes an array of unassigned documents and creates InkContainers 
    // for series matching known syntax (e.g. "Batman Vol. 1", "Batman Vol. 2")
    func performSmartGrouping(context: ModelContext) {
        // Fetch all documents and filter in memory to dodge `#Predicate` translation limitations on optional arrays
        let fetchDescriptor = FetchDescriptor<SDConvertedPDF>()
        guard let allDocs = try? context.fetch(fetchDescriptor) else { return }
        let orphans = allDocs.filter { $0.collectionId == nil }
        
        var groupedByName: [String: [SDConvertedPDF]] = [:]
        
        for doc in orphans {
            // Priority 1: Use Explicit Metadata Series
            if let explicitSeries = doc.metadata.series, !explicitSeries.isEmpty {
                groupedByName[explicitSeries, default: []].append(doc)
                continue
            }
            
            // Priority 2: Use file regex stripping issue numbers
            let seriesBaseName = doc.name.replacingOccurrences(of: #"(?i)(\svol(\.|ume)?\s*\d+|\sissue\s*\d+|\s#\d+|\s-\s\d+).*"#, with: "", options: String.CompareOptions.regularExpression).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
            groupedByName[seriesBaseName, default: []].append(doc)
        }
        
        var generatedCount = 0
        
        for (seriesName, docs) in groupedByName {
            // Only group if there are at least 2 matching items
            if docs.count > 1 {
                // Check if container already exists
                let namePredicate = #Predicate<SDPDFCollection> { $0.name == seriesName }
                var existingContainer: SDPDFCollection?
                if let fetchRes = try? context.fetch(FetchDescriptor(predicate: namePredicate)), let match = fetchRes.first {
                    existingContainer = match
                }
                
                let container = existingContainer ?? SDPDFCollection(id: UUID(), name: seriesName, icon: "folder", color: "blue", creationDate: Date(), explicitCoverFileID: nil)
                if existingContainer == nil {
                    context.insert(container)
                    generatedCount += 1
                }
                
                for doc in docs {
                    doc.collectionId = container.id
                }
            }
        }
        
        if generatedCount > 0 {
            try? context.save()
            Logger.shared.log("Smart Grouping generated \(generatedCount) new recursive series collections.", category: "Library")
        }
    }
    
    // ✅ NEW: Dual-Write Background Sync
    // Silently builds the SwiftData database while legacy monolithic arrays are still being used by the UI layer.
    func syncToSwiftData(pdfs: [ConvertedPDF], collections: [PDFCollection]) {
        Task.detached(priority: .background) {
            do {
                let container = try ModelContainer(for: SDConvertedPDF.self, SDPDFCollection.self)
                let context = ModelContext(container)
                
                // 1. Sync Collections
                for col in collections {
                    let colId = col.id
                    let predicate = #Predicate<SDPDFCollection> { $0.id == colId }
                    var existing: SDPDFCollection?
                    if let fetchRes = try? context.fetch(FetchDescriptor(predicate: predicate)), let match = fetchRes.first {
                        existing = match
                    }
                    if let existing = existing {
                        existing.name = col.name
                        existing.icon = col.icon
                        existing.color = col.color
                        existing.explicitCoverFileID = col.explicitCoverFileID
                    } else {
                        let newCol = SDPDFCollection(id: col.id, name: col.name, icon: col.icon, color: col.color, creationDate: col.creationDate, explicitCoverFileID: col.explicitCoverFileID)
                        context.insert(newCol)
                    }
                }
                
                // 2. Sync PDFs
                for pdf in pdfs {
                    let pdfId = pdf.id
                    let predicate = #Predicate<SDConvertedPDF> { $0.id == pdfId }
                    var existingDoc: SDConvertedPDF?
                    if let fetchRes = try? context.fetch(FetchDescriptor(predicate: predicate)), let match = fetchRes.first {
                        existingDoc = match
                    }
                    
                    if let existing = existingDoc {
                        existing.name = pdf.name
                        existing.pageCount = pdf.pageCount
                        existing.fileSize = pdf.fileSize
                        existing.metadata = pdf.metadata
                        existing.collectionId = pdf.collectionId
                        existing.isFavorite = pdf.isFavorite
                        existing.isPrivate = pdf.isPrivate
                        existing.contentType = pdf.contentType
                        existing.addedByMode = pdf.addedByMode
                    } else {
                        let doc = SDConvertedPDF(id: pdf.id, name: pdf.name, url: pdf.url, pageCount: pdf.pageCount, fileSize: pdf.fileSize, metadata: pdf.metadata, collectionId: pdf.collectionId, isFavorite: pdf.isFavorite, isPrivate: pdf.isPrivate, coverImageData: pdf.coverImageData, contentType: pdf.contentType, chapters: pdf.chapters, addedByMode: pdf.addedByMode)
                        context.insert(doc)
                    }
                }
                // 3. Prune Deleted or Orphaned Duplicates
                let validPDFIds = Set(pdfs.map { $0.id })
                if let allExisting = try? context.fetch(FetchDescriptor<SDConvertedPDF>()) {
                    for existing in allExisting {
                        if !validPDFIds.contains(existing.id) {
                            context.delete(existing)
                        }
                    }
                }
                
                let validColIds = Set(collections.map { $0.id })
                if let allExistingCols = try? context.fetch(FetchDescriptor<SDPDFCollection>()) {
                    for existingCol in allExistingCols {
                        if !validColIds.contains(existingCol.id) {
                            context.delete(existingCol)
                        }
                    }
                }
                
                try context.save()
            } catch {
                Logger.shared.log("Dual-Write SwiftData sync failed: \(error.localizedDescription)", category: "Migration", type: .error)
            }
        }
    }
    
    // ✅ NEW: Native SwiftData Read Bridge
    // Replaces `inksync_pro_library.json` loading array bloat from Phase 1.
    func fetchSwiftDataLegacyBridge() async throws -> ([SDConvertedPDF], [SDPDFCollection]) {
         let container = try ModelContainer(for: SDConvertedPDF.self, SDPDFCollection.self)
         let context = container.mainContext
         
         let docDesc = FetchDescriptor<SDConvertedPDF>()
         let colDesc = FetchDescriptor<SDPDFCollection>()
         
         let docs = try context.fetch(docDesc)
         let cols = try context.fetch(colDesc)
         
         return (docs, cols)
    }
}

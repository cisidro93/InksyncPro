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
        
        var containerMap: [UUID: InkContainer] = [:]
        
        // 1. Insert Containers
        for col in legacyCollections {
            let container = InkContainer(id: col.id, name: col.name, icon: col.icon, color: col.color, creationDate: col.creationDate, explicitCoverFileID: col.explicitCoverFileID)
            context.insert(container)
            containerMap[col.id] = container
        }
        
        // 2. Insert Documents and Relate
        for pdf in legacyPDFs {
            let doc = InkDocument(id: pdf.id, name: pdf.name, url: pdf.url, pageCount: pdf.pageCount, fileSize: pdf.fileSize, metadata: pdf.metadata, isFavorite: pdf.isFavorite, isPrivate: pdf.isPrivate, coverImageData: pdf.coverImageData, contentType: pdf.contentType, chapters: pdf.chapters, addedByMode: pdf.addedByMode)
            
            // Re-establish relationships natively in SwiftData
            if let colId = pdf.collectionId, let parentContainer = containerMap[colId] {
                doc.container = parentContainer
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
        let fetchDescriptor = FetchDescriptor<InkDocument>(predicate: #Predicate { $0.container == nil })
        guard let orphans = try? context.fetch(fetchDescriptor) else { return }
        
        var groupedByName: [String: [InkDocument]] = [:]
        
        for doc in orphans {
            // Priority 1: Use Explicit Metadata Series
            if let explicitSeries = doc.metadata.series, !explicitSeries.isEmpty {
                groupedByName[explicitSeries, default: []].append(doc)
                continue
            }
            
            // Priority 2: Use file regex stripping issue numbers
            let seriesBaseName = doc.name.replacingOccurrences(of: #"(?i)(\svol(\.|ume)?\s*\d+|\sissue\s*\d+|\s#\d+|\s-\s\d+).*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            
            groupedByName[seriesBaseName, default: []].append(doc)
        }
        
        var generatedCount = 0
        
        for (seriesName, docs) in groupedByName {
            // Only group if there are at least 2 matching items
            if docs.count > 1 {
                // Check if container already exists
                let namePredicate = #Predicate<InkContainer> { $0.name == seriesName }
                var existingContainer: InkContainer?
                if let fetchRes = try? context.fetch(FetchDescriptor(predicate: namePredicate)), let match = fetchRes.first {
                    existingContainer = match
                }
                
                let container = existingContainer ?? InkContainer(name: seriesName)
                if existingContainer == nil {
                    context.insert(container)
                    generatedCount += 1
                }
                
                for doc in docs {
                    doc.container = container
                }
            }
        }
        
        if generatedCount > 0 {
            try? context.save()
            Logger.shared.log("Smart Grouping generated \(generatedCount) new recursive series collections.", category: "Library")
        }
    }
}

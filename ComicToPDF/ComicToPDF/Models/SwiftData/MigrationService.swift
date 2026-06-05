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
        // Fetch all documents and filter in memory to dodge `#Predicate` translation limitations on optional arrays
        let fetchDescriptor = FetchDescriptor<SDConvertedPDF>()
        guard let allDocs = try? context.fetch(fetchDescriptor) else { return 0 }
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
        var assignedCount = 0
        
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
                    if doc.collectionId != container.id {
                        doc.collectionId = container.id
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
    
    @MainActor
    func runZettelkastenNLPBackfill(context: ModelContext) {
        if UserDefaults.standard.bool(forKey: "zettelNLPBackfillVersion_v1") { return }
        
        let fetchDescriptor = FetchDescriptor<SDAnnotation>()
        let allAnnotations = (try? context.fetch(fetchDescriptor)) ?? []
        
        let targets = allAnnotations.filter { 
            ($0.tags?.isEmpty ?? true) && 
            $0.kindRaw == "highlight" && 
            $0.selectedText != nil && 
            $0.selectedText?.isEmpty == false 
        }.map { ($0.id, $0.selectedText!) }
        
        guard !targets.isEmpty else {
            UserDefaults.standard.set(true, forKey: "zettelNLPBackfillVersion_v1")
            return
        }
        
        Logger.shared.log("Starting NLP backfill for \(targets.count) annotations...", category: "Migration")
        
        Task {
            let results = await Task.detached(priority: .background) { () -> [(UUID, [String])] in
                var extracted: [(UUID, [String])] = []
                for (id, text) in targets {
                    let tags = await AnnotationStore.shared.extractNLPKeywords(from: text)
                    extracted.append((id, tags))
                }
                return extracted
            }.value
            
            for (id, tags) in results {
                let refreshDescriptor = FetchDescriptor<SDAnnotation>(
                    predicate: #Predicate { $0.id == id }
                )
                if let annotation = try? context.fetch(refreshDescriptor).first {
                    annotation.tags = tags
                }
            }
            try? context.save()
            UserDefaults.standard.set(true, forKey: "zettelNLPBackfillVersion_v1")
            Logger.shared.log("Completed NLP backfill migration successfully.", category: "Migration")
        }
    }
    
    // ✅ Full reconciliation sync (used on app save / quit).
    // Fetches entire DB, upserts changed records, prunes deleted ones.
    // O(n) in library size. Do NOT call this in a tight per-file loop.
    func syncToSwiftData(pdfs: [ConvertedPDF], collections: [PDFCollection]) {
        let container = InksyncProApp.sharedModelContainer
        Task.detached(priority: .background) { () async -> Void in
            do {
                let context = ModelContext(container)

                // O(1) Bulk Fetch Collections
                let allExistingCols = (try? context.fetch(FetchDescriptor<SDPDFCollection>())) ?? []
                let colDict = Dictionary(grouping: allExistingCols, by: { $0.id }).compactMapValues { $0.first }

                // 1. Sync Collections
                for col in collections {
                    if let existing = colDict[col.id] {
                        existing.name = col.name
                        existing.icon = col.icon
                        existing.color = col.color
                        existing.explicitCoverFileID = col.explicitCoverFileID
                    } else {
                        let newCol = SDPDFCollection(id: col.id, name: col.name, icon: col.icon, color: col.color, creationDate: col.creationDate, explicitCoverFileID: col.explicitCoverFileID)
                        context.insert(newCol)
                    }
                }

                // O(1) Bulk Fetch PDFs — build ID set for upsert logic
                let allExistingPdfs = (try? context.fetch(FetchDescriptor<SDConvertedPDF>())) ?? []
                let pdfDict = Dictionary(grouping: allExistingPdfs, by: { $0.id }).compactMapValues { $0.first }

                // 2. Sync PDFs
                for pdf in pdfs {
                    if let existing = pdfDict[pdf.id] {
                        if existing.name != pdf.name { existing.name = pdf.name }
                        if existing.pageCount != pdf.pageCount { existing.pageCount = pdf.pageCount }
                        if existing.fileSize != pdf.fileSize { existing.fileSize = pdf.fileSize }
                        if existing.metadata != pdf.metadata { existing.metadata = pdf.metadata }
                        if existing.collectionId != pdf.collectionId { existing.collectionId = pdf.collectionId }
                        if existing.isFavorite != pdf.isFavorite { existing.isFavorite = pdf.isFavorite }
                        if existing.isPrivate != pdf.isPrivate { existing.isPrivate = pdf.isPrivate }
                        if existing.contentType != pdf.contentType { existing.contentType = pdf.contentType }
                        if existing.addedByMode != pdf.addedByMode { existing.addedByMode = pdf.addedByMode }
                        if let encoded = try? JSONEncoder().encode(pdf.sourceMode), existing.sourceModeData != encoded {
                            existing.sourceModeData = encoded
                        }
                    } else {
                        let doc = SDConvertedPDF(id: pdf.id, name: pdf.name, url: pdf.url, pageCount: pdf.pageCount, fileSize: pdf.fileSize, metadata: pdf.metadata, collectionId: pdf.collectionId, isFavorite: pdf.isFavorite, isPrivate: pdf.isPrivate, coverImageData: pdf.coverImageData, contentType: pdf.contentType, chapters: pdf.chapters, addedByMode: pdf.addedByMode, sourceMode: pdf.sourceMode)
                        context.insert(doc)
                    }
                }

                // 3. Prune Deleted or Orphaned Duplicates
                let validPDFIds = Set(pdfs.map { $0.id })
                for existing in allExistingPdfs where !validPDFIds.contains(existing.id) {
                    context.delete(existing)
                }

                let validColIds = Set(collections.map { $0.id })
                for existingCol in allExistingCols where !validColIds.contains(existingCol.id) {
                    context.delete(existingCol)
                }

                try context.save()
            } catch {
                Logger.shared.log("Dual-Write SwiftData sync failed: \(error.localizedDescription)", category: "Migration", type: .error)
            }
        }
    }

    // ✅ Fast import-only insert path.
    // Called at the end of an import batch with ONLY the newly imported PDFs.
    // Skips the expensive full-table fetch + upsert loop — just inserts new rows
    // and saves once. The next full syncToSwiftData (app save) will reconcile.
    func batchInsertToSwiftData(newPDFs: [ConvertedPDF]) {
        guard !newPDFs.isEmpty else { return }
        let container = InksyncProApp.sharedModelContainer
        do {
            let context = container.mainContext
            // Fetch IDs to avoid duplicate inserts
            let idDesc = FetchDescriptor<SDConvertedPDF>()
            let existingIDs = Set((try? context.fetch(idDesc))?.map { $0.id } ?? [])

            var insertCount = 0
            for pdf in newPDFs where !existingIDs.contains(pdf.id) {
                let doc = SDConvertedPDF(
                    id: pdf.id, name: pdf.name, url: pdf.url,
                    pageCount: pdf.pageCount, fileSize: pdf.fileSize,
                    metadata: pdf.metadata, collectionId: pdf.collectionId,
                    isFavorite: pdf.isFavorite, isPrivate: pdf.isPrivate,
                    coverImageData: nil, // cover written separately by PhysicalFileSystemRouter
                    contentType: pdf.contentType, chapters: pdf.chapters,
                    addedByMode: pdf.addedByMode, sourceMode: pdf.sourceMode
                )
                context.insert(doc)
                insertCount += 1
            }
            if insertCount > 0 {
                try context.save()
                Logger.shared.log("batchInsertToSwiftData: committed \(insertCount) new record(s)", category: "Migration")
            }
        } catch {
            Logger.shared.log("batchInsertToSwiftData failed: \(error.localizedDescription)", category: "Migration", type: .error)
        }
    }
    
    // ✅ Native SwiftData Read Bridge
    // Replaces `inksync_pro_library.json` loading array bloat from Phase 1.
    func fetchSwiftDataLegacyBridge() async throws -> ([SDConvertedPDF], [SDPDFCollection]) {
        let context = InksyncProApp.sharedModelContainer.mainContext

        let docDesc = FetchDescriptor<SDConvertedPDF>()
        let colDesc = FetchDescriptor<SDPDFCollection>()
        let annDesc = FetchDescriptor<SDAnnotation>()

        let docs = try context.fetch(docDesc)
        let cols = try context.fetch(colDesc)
        let annotations = (try? context.fetch(annDesc)) ?? []

        // ── Path Re-Anchor ──────────────────────────────────────────────────
        // After an app update the iOS sandbox container UUID rotates, making every
        // stored absolute URL stale. Instead of deleting records (which wipes the
        // library), we re-anchor the URL by searching for the file by name inside
        // the current vault directory.
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let currentSandboxPath = appSupport?.path ?? ""
        
        let lastSandboxPath = UserDefaults.standard.string(forKey: "lastSandboxDocumentsPath")
        if !currentSandboxPath.isEmpty && lastSandboxPath == currentSandboxPath {
            Logger.shared.log("MigrationService: Sandbox path matches, skipping re-anchoring check for \(docs.count) doc(s)", category: "Migration", type: .info)
            return (docs, cols)
        }

        let vaultRoot = appSupport?.appendingPathComponent("InksyncVault", isDirectory: true)
        let inboxRoot = appSupport?.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
        let docsRoot = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first

        let possibleRoots = [vaultRoot, inboxRoot, docsRoot].compactMap { $0 }

        var validDocs: [SDConvertedPDF] = []
        var ghostIDs: Set<UUID> = []
        var didUpdate = false

        for doc in docs {
            // 1. If the absolute path still works (no update occurred or it's a connected external drive), keep it.
            if fileManager.fileExists(atPath: doc.url.path) {
                validDocs.append(doc)
                continue
            }
            
            // 2. If it's a linked file (external drive), we DO NOT try to re-anchor it to the local vault.
            if let data = doc.sourceModeData, let mode = try? JSONDecoder().decode(SourceMode.self, from: data), mode.isLinked {
                validDocs.append(doc)
                continue
            }

            // 3. Try to re-anchor by filename across all Known Vaults in the new Sandbox UUID
            let filename = doc.url.lastPathComponent
            var foundReanchor = false

            for root in possibleRoots {
                let reanchored = root.appendingPathComponent(filename)
                if fileManager.fileExists(atPath: reanchored.path) {
                    doc.url = reanchored          // fix the stale absolute path
                    didUpdate = true
                    validDocs.append(doc)
                    Logger.shared.log("MigrationService: Re-anchored '\(filename)' to \(root.lastPathComponent)", category: "Migration")
                    foundReanchor = true
                    break
                }
            }

            if !foundReanchor {
                // File genuinely missing — DELETE the record permanently.
                // Ghost files are caused by iCloud restoring old SwiftData SQLite databases
                // after a clean reinstall. We eradicate them so they never come back.
                ghostIDs.insert(doc.id)
                context.delete(doc)
                Logger.shared.log("MigrationService: Eradicated ghost record '\(filename)' from SwiftData", category: "Migration", type: .warning)
                didUpdate = true
            }
        }

        // ── Cascade-delete annotations that belonged to ghost books ────────
        if !ghostIDs.isEmpty {
            for annotation in annotations {
                if ghostIDs.contains(annotation.pdfID) {
                    context.delete(annotation)
                }
            }
            Logger.shared.log("MigrationService: Purged annotations for \(ghostIDs.count) ghost book(s)", category: "Migration", type: .warning)
        }

        // ── Prune orphaned SDPDFCollection series shells ─────────────────────
        // After ghost books are eradicated, any SDPDFCollection that has ZERO
        // surviving books is itself a ghost series shell. If left alive it shows
        // up as an empty folder in the Library on a fresh install.
        let survivingCollectionIDs = Set(validDocs.compactMap { $0.collectionId })
        var ghostCollectionNames: [String] = []
        var validCols: [SDPDFCollection] = []
        for col in cols {
            if survivingCollectionIDs.contains(col.id) {
                validCols.append(col)
            } else {
                ghostCollectionNames.append(col.name)
                context.delete(col)
                didUpdate = true
                Logger.shared.log("MigrationService: Eradicated ghost series shell '\(col.name)'", category: "Migration", type: .warning)
            }
        }
        if !ghostCollectionNames.isEmpty {
            Logger.shared.log("MigrationService: Purged \(ghostCollectionNames.count) orphaned series collection(s)", category: "Migration", type: .warning)
        }

        // ── Prune orphaned SDSeriesMemory records ─────────────────────────
        // SDSeriesMemory stores per-series learning (RTL, panel confidence, etc.).
        // On a clean reinstall the iCloud-restored SQLite may still carry these.
        // We always run this purge: orphaned memory can accumulate even when no
        // explicit collection ghosts were detected (e.g. smart-grouped series that
        // were later manually disbanded).
        let liveSeriesNames = Set(validCols.map { $0.name.lowercased().trimmingCharacters(in: .whitespaces) })
        let seriesMemDesc = FetchDescriptor<SDSeriesMemory>()
        let allSeriesMemory = (try? context.fetch(seriesMemDesc)) ?? []
        var purgedMemoryCount = 0
        for memory in allSeriesMemory {
            let normalised = memory.seriesNameNormalized.lowercased().trimmingCharacters(in: .whitespaces)
            if !liveSeriesNames.contains(normalised) {
                context.delete(memory)
                purgedMemoryCount += 1
                didUpdate = true
            }
        }
        if purgedMemoryCount > 0 {
            Logger.shared.log("MigrationService: Purged \(purgedMemoryCount) orphaned SDSeriesMemory record(s)", category: "Migration", type: .warning)
        }

        if didUpdate {
            try? context.save()
        }

        if !currentSandboxPath.isEmpty {
            UserDefaults.standard.set(currentSandboxPath, forKey: "lastSandboxDocumentsPath")
        }

        return (validDocs, validCols)
    }
}

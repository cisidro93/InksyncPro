import Foundation
import SwiftData

/// A Swift 6 ModelActor executing database operations on a thread-isolated background context.
@ModelActor
actor LibraryModelActor {
    
    /// Fetches all documents, re-anchors sandboxed paths, and prunes orphaned metadata (annotations, collections, memories).
    /// Returns Sendable ConvertedPDF structs to safely cross the actor boundary.
    func fetchAllDocuments() throws -> [ConvertedPDF] {
        let descriptor = FetchDescriptor<SDConvertedPDF>()
        let documents = try modelContext.fetch(descriptor)
        
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let docsRoot = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        
        let vaultRoot = appSupport?.appendingPathComponent("InksyncVault", isDirectory: true)
        let inboxRoot = appSupport?.appendingPathComponent("InksyncVault/Inbox", isDirectory: true)
        let possibleRoots = [vaultRoot, inboxRoot, docsRoot].compactMap { $0 }
        
        var didUpdate = false
        var validDocs: [SDConvertedPDF] = []
        var ghostIDs: Set<UUID> = []
        
        let currentSandboxPath = appSupport?.path ?? ""
        let lastSandboxPath = UserDefaults.standard.string(forKey: "lastSandboxDocumentsPath")
        let isNewSandbox = !currentSandboxPath.isEmpty && lastSandboxPath != currentSandboxPath
        
        for doc in documents {
            // 1. If physical file exists, path is already correct
            if fileManager.fileExists(atPath: doc.url.path) {
                validDocs.append(doc)
                continue
            }
            
            // 2. Ignore re-anchoring for external/linked files
            if let data = doc.sourceModeData, let mode = try? JSONDecoder().decode(SourceMode.self, from: data) {
                if mode.isLinked || mode.isCloud {
                    validDocs.append(doc)
                    continue
                }
            }
            
            // 3. Try smart relative re-anchoring (preserves subdirectory structure)
            let oldPath = doc.url.path
            var foundReanchor = false
            var checkURL: URL?
            
            if let docRange = oldPath.range(of: "/Documents/") {
                let relPath = String(oldPath[docRange.upperBound...])
                if let docsRoot = docsRoot {
                    let testURL = docsRoot.appendingPathComponent(relPath)
                    if fileManager.fileExists(atPath: testURL.path) {
                        checkURL = testURL
                        foundReanchor = true
                    }
                }
            }
            
            if !foundReanchor, let appSupport = appSupport {
                if let inboxRange = oldPath.range(of: "/InksyncVault/Inbox/") {
                    let relPath = String(oldPath[inboxRange.upperBound...])
                    let testURL = appSupport.appendingPathComponent("InksyncVault/Inbox").appendingPathComponent(relPath)
                    if fileManager.fileExists(atPath: testURL.path) {
                        checkURL = testURL
                        foundReanchor = true
                    }
                }
                
                if !foundReanchor, let vaultRange = oldPath.range(of: "/InksyncVault/") {
                    let relPath = String(oldPath[vaultRange.upperBound...])
                    if !relPath.hasPrefix("Inbox/") {
                        let testURL = appSupport.appendingPathComponent("InksyncVault").appendingPathComponent(relPath)
                        if fileManager.fileExists(atPath: testURL.path) {
                            checkURL = testURL
                            foundReanchor = true
                        }
                    }
                }
            }
            
            // 4. Fallback: Try re-anchoring by filename only across all sandbox roots
            if !foundReanchor {
                let filename = doc.url.lastPathComponent
                for root in possibleRoots {
                    let testURL = root.appendingPathComponent(filename)
                    if fileManager.fileExists(atPath: testURL.path) {
                        checkURL = testURL
                        foundReanchor = true
                        break
                    }
                }
            }
            
            if foundReanchor, let finalURL = checkURL {
                doc.url = finalURL
                didUpdate = true
                validDocs.append(doc)
            } else {
                // File genuinely missing — mark as ghost and delete
                ghostIDs.insert(doc.id)
                modelContext.delete(doc)
                didUpdate = true
            }
        }
        
        // ── Cascade-delete annotations that belonged to ghost books ────────
        if !ghostIDs.isEmpty {
            let annotations = (try? modelContext.fetch(FetchDescriptor<SDAnnotation>())) ?? []
            for annotation in annotations {
                if ghostIDs.contains(annotation.pdfID) {
                    modelContext.delete(annotation)
                }
            }
        }
        
        // ── Clean up invalid collection IDs pointing to non-existent collections ──
        let sdCols = try modelContext.fetch(FetchDescriptor<SDPDFCollection>())
        let existingColIDs = Set(sdCols.map { $0.id })
        for doc in validDocs {
            if let cid = doc.collectionId, !existingColIDs.contains(cid) {
                doc.collectionId = nil
                didUpdate = true
            }
        }

        // ── One-time self-healing pass for series names and content type classification ──
        for doc in validDocs {
            // 1. Strip leading sequential prefixes from series name
            if let series = doc.metadata.series, !series.isEmpty {
                let cleaned = series.replacingOccurrences(of: #"^(?:0\d+|\d{1,2})[\s_.-]+(?=[a-zA-Z])"#, with: "", options: .regularExpression)
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned != series {
                    doc.metadata.series = cleaned
                    didUpdate = true
                }
            }
            
            // 2. Heal content type: if it's a comic but matches manga signatures, re-classify
            let currentType = doc.contentType
            var inferredType = currentType
            
            let urlPath = doc.url.path.lowercased()
            let filename = doc.url.lastPathComponent.lowercased()
            let mangaKeywords = ["[raw]", "[ch.", "ch.", "manhwa", "manhua", "manga", "scanlation", "oneshot", "doujin", "tankobon", "volume", "chapter", "shonen", "shoujo", "seinen", "josei"]
            
            let isMangaMetadata = doc.metadata.isManga ?? false
            let hasMangaInPath = urlPath.contains("/manga/") || urlPath.contains("/manga") || doc.url.pathComponents.map({ $0.lowercased() }).contains("manga")
            let hasMangaInFilename = mangaKeywords.contains(where: { filename.contains($0) })
            
            if isMangaMetadata || hasMangaInPath || hasMangaInFilename {
                inferredType = .manga
            }
            
            if inferredType != currentType {
                doc.contentType = inferredType
                didUpdate = true
            }
        }
        
        // Strip sequential prefixes from existing collection names
        for col in sdCols {
            let name = col.name
            let cleaned = name.replacingOccurrences(of: #"^(?:0\d+|\d{1,2})[\s_.-]+(?=[a-zA-Z])"#, with: "", options: .regularExpression)
                              .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned != name {
                col.name = cleaned
                didUpdate = true
            }
        }
        
        // ── Prune orphaned SDPDFCollection series shells ─────────────────────
        let survivingCollectionIDs = Set(validDocs.compactMap { $0.collectionId })
        var validCols: [SDPDFCollection] = []
        for col in sdCols {
            if survivingCollectionIDs.contains(col.id) {
                validCols.append(col)
            } else {
                modelContext.delete(col)
                didUpdate = true
            }
        }
        
        // ── Prune orphaned SDSeriesMemory records ─────────────────────────
        let liveSeriesNames = Set(validCols.map { $0.name.lowercased().trimmingCharacters(in: .whitespaces) })
        let allSeriesMemory = (try? modelContext.fetch(FetchDescriptor<SDSeriesMemory>())) ?? []
        for memory in allSeriesMemory {
            let normalised = memory.seriesNameNormalized.lowercased().trimmingCharacters(in: .whitespaces)
            if !liveSeriesNames.contains(normalised) {
                modelContext.delete(memory)
                didUpdate = true
            }
        }
        
        if didUpdate {
            try? modelContext.save()
        }
        
        if isNewSandbox {
            UserDefaults.standard.set(currentSandboxPath, forKey: "lastSandboxDocumentsPath")
        }
        
        return validDocs.map { $0.toDTO() }
    }
    
    /// Fetches all collection series shells as Sendable DTO structs.
    func fetchAllCollections() throws -> [PDFCollection] {
        let descriptor = FetchDescriptor<SDPDFCollection>()
        let cols = try modelContext.fetch(descriptor)
        return cols.map { $0.toDTO() }
    }
    
    /// Fast batch insert path for newly imported PDF records.
    func batchInsertPDFs(newPDFs: [ConvertedPDF]) throws {
        let descriptor = FetchDescriptor<SDConvertedPDF>()
        let existingIDs = Set((try? modelContext.fetch(descriptor))?.map { $0.id } ?? [])
        
        var inserted = 0
        for pdf in newPDFs where !existingIDs.contains(pdf.id) {
            let doc = SDConvertedPDF(
                id: pdf.id, name: pdf.name, url: pdf.url,
                pageCount: pdf.pageCount, fileSize: pdf.fileSize,
                metadata: pdf.metadata, collectionId: pdf.collectionId,
                isFavorite: pdf.isFavorite, isPrivate: pdf.isPrivate,
                coverImageData: nil,
                contentType: pdf.contentType, chapters: pdf.chapters,
                addedByMode: pdf.addedByMode, sourceMode: pdf.sourceMode
            )
            modelContext.insert(doc)
            inserted += 1
        }
        
        if inserted > 0 {
            try modelContext.save()
        }
    }
    
    /// Synchronizes files and collections to SwiftData, pruning deleted records.
    func syncToSwiftData(pdfs: [ConvertedPDF], collections: [PDFCollection]) throws {
        // 1. Sync Collections
        let existingCols = try modelContext.fetch(FetchDescriptor<SDPDFCollection>())
        let colDict = Dictionary(grouping: existingCols, by: { $0.id }).compactMapValues { $0.first }
        
        for col in collections {
            if let existing = colDict[col.id] {
                existing.name = col.name
                existing.icon = col.icon
                existing.color = col.color
                existing.explicitCoverFileID = col.explicitCoverFileID
            } else {
                let newCol = SDPDFCollection(
                    id: col.id, name: col.name, icon: col.icon,
                    color: col.color, creationDate: col.creationDate,
                    explicitCoverFileID: col.explicitCoverFileID
                )
                modelContext.insert(newCol)
            }
        }
        
        // 2. Sync PDFs
        let existingPDFs = try modelContext.fetch(FetchDescriptor<SDConvertedPDF>())
        let pdfDict = Dictionary(grouping: existingPDFs, by: { $0.id }).compactMapValues { $0.first }
        
        for pdf in pdfs {
            if let existing = pdfDict[pdf.id] {
                if existing.name != pdf.name { existing.name = pdf.name }
                if existing.url != pdf.url { existing.url = pdf.url }
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
                let doc = SDConvertedPDF(
                    id: pdf.id, name: pdf.name, url: pdf.url,
                    pageCount: pdf.pageCount, fileSize: pdf.fileSize,
                    metadata: pdf.metadata, collectionId: pdf.collectionId,
                    isFavorite: pdf.isFavorite, isPrivate: pdf.isPrivate,
                    coverImageData: pdf.coverImageData, contentType: pdf.contentType,
                    chapters: pdf.chapters, addedByMode: pdf.addedByMode,
                    sourceMode: pdf.sourceMode
                )
                modelContext.insert(doc)
            }
        }
        
        // 3. Prune deleted PDFs
        let validPDFIDs = Set(pdfs.map { $0.id })
        for existing in existingPDFs where !validPDFIDs.contains(existing.id) {
            modelContext.delete(existing)
        }
        
        // 4. Prune deleted collections
        let validColIDs = Set(collections.map { $0.id })
        for existingCol in existingCols where !validColIDs.contains(existingCol.id) {
            modelContext.delete(existingCol)
        }
        
        try modelContext.save()
    }
    
    /// Triggers smart grouping dynamically on the background database context.
    func performSmartGrouping() throws -> Int {
        return MigrationService.performSmartGroupingInternal(context: modelContext)
    }
}

/// The main application coordinator for library database management.
final class LibraryRepository: Sendable {
    static let shared = LibraryRepository(container: InksyncProApp.sharedModelContainer)
    
    private let modelContainer: ModelContainer
    private let actor: LibraryModelActor
    
    init(container: ModelContainer) {
        self.modelContainer = container
        self.actor = LibraryModelActor(modelContainer: container)
    }
    
    /// Asynchronously fetches all library items and collections from SwiftData background context.
    func loadLibrary() async throws -> ([ConvertedPDF], [PDFCollection]) {
        let pdfs = try await actor.fetchAllDocuments()
        let cols = try await actor.fetchAllCollections()
        return (pdfs, cols)
    }
    
    /// Runs direct background batch insertion for newly imported items.
    func batchInsert(newPDFs: [ConvertedPDF]) async throws {
        try await actor.batchInsertPDFs(newPDFs: newPDFs)
    }
    
    /// Synchronizes both collections and files on a background model context.
    func sync(pdfs: [ConvertedPDF], collections: [PDFCollection]) async throws {
        try await actor.syncToSwiftData(pdfs: pdfs, collections: collections)
    }
    
    /// Runs smart grouping on the thread-isolated background actor context.
    func performSmartGrouping() async throws -> Int {
        try await actor.performSmartGrouping()
    }
}

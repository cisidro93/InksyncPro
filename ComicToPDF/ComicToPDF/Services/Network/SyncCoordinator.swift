import Foundation
import SwiftData

/// Represents the raw JSON payload securely beamed across the local network
struct SyncPayload: Codable {
    let pdfs: [ConvertedPDF]
    let collections: [PDFCollection]
    let exportDate: Date
}

/// A deterministic merging engine that safely maps incoming SyncPayloads directly into the active SwiftData layer.
@MainActor
class SyncCoordinator: ObservableObject {
    static let shared = SyncCoordinator()
    
    @Published var isSyncing: Bool = false
    @Published var syncStatus: String = ""
    
    private init() {}
    
    /// Exports the monolithic library state directly out of SwiftData into a secure network-ready JSON container.
    func exportDatabase() throws -> SyncPayload {
        let context = InksyncProApp.sharedModelContainer.mainContext
        
        let pdfs = try context.fetch(FetchDescriptor<SDConvertedPDF>()).map { $0.toDTO() }
        let collections = try context.fetch(FetchDescriptor<SDPDFCollection>()).map { $0.toDTO() }
        
        return SyncPayload(pdfs: pdfs, collections: collections, exportDate: Date())
    }
    
    /// Bypasses the local ConversionManager loop to surgically merge incoming P2P records directly into SwiftData.
    func mergeIncomingPayload(data: Data) async throws -> [String] {
        self.isSyncing = true
        self.syncStatus = "Parsing Database Payload..."
        defer { self.isSyncing = false }
        
        let payload = try JSONDecoder().decode(SyncPayload.self, from: data)
        self.syncStatus = "Matching Incoming PDF Metadata..."
        
        // Ensure Database Context is ready
        let context = InksyncProApp.sharedModelContainer.mainContext
        
        // 1. Map Existing SwiftData Items to LastPathComponent Identity Check
        let existingPDFs = try context.fetch(FetchDescriptor<SDConvertedPDF>())
        var localMapping = [String: SDConvertedPDF]()
        for e in existingPDFs {
            localMapping[e.url.lastPathComponent] = e
        }
        
        // 2. Safely Extract Missing UUIDs for collections
        let existingCollections = try context.fetch(FetchDescriptor<SDPDFCollection>())
        // Index by UUID (primary) AND name (fallback for cross-device imports where UUIDs diverge)
        var localCollectionByID   = [UUID:   SDPDFCollection]()
        var localCollectionByName = [String: SDPDFCollection]()
        for col in existingCollections {
            localCollectionByID[col.id]     = col
            localCollectionByName[col.name] = col
        }
        // Build a name-to-local-ID map for remapping incoming PDF collectionIds
        var localCollectionMapping = [String: SDPDFCollection]()
        for col in existingCollections { localCollectionMapping[col.name] = col }

        for incomingCol in payload.collections {
            if let existing = localCollectionByID[incomingCol.id] ?? localCollectionByName[incomingCol.name] {
                // Update mutable properties; preserve the local UUID
                existing.name = incomingCol.name
                existing.icon = incomingCol.icon
                existing.color = incomingCol.color
                existing.creationDate = incomingCol.creationDate
                existing.explicitCoverFileID = incomingCol.explicitCoverFileID
                existing.parentId = incomingCol.parentId
                localCollectionMapping[incomingCol.name] = existing
            } else {
                let newCol = SDPDFCollection(id: incomingCol.id, name: incomingCol.name, icon: incomingCol.icon, color: incomingCol.color, creationDate: incomingCol.creationDate, explicitCoverFileID: incomingCol.explicitCoverFileID, parentId: incomingCol.parentId)
                context.insert(newCol)
                localCollectionMapping[newCol.name] = newCol
            }
        }
        
        // 3. Compare Progress Engine Checkpoints
        var importedCopiesCount = 0
        var overwrittenMetadataCount = 0
        
        var missingFiles: [String] = []
        
        for incomingPDF in payload.pdfs {
            let filename = incomingPDF.url.lastPathComponent
            
            // Need to remap collection IDs to local Context IDs just in case
            var assignedLocalCollectionID: UUID? = incomingPDF.collectionId
            if let foreignCID = incomingPDF.collectionId, let foreignColName = payload.collections.first(where: {$0.id == foreignCID})?.name {
                assignedLocalCollectionID = localCollectionMapping[foreignColName]?.id
            }
            
            if let existing = localMapping[filename] {
                let incomingPage = incomingPDF.metadata.lastReadPage ?? 0
                let localPage = existing.metadata.lastReadPage ?? 0
                
                let incomingLastModified = incomingPDF.lastModified
                let localLastModified = existing.lastModified
                
                // Adopt incoming metadata if incoming is newer or page progressed further
                if incomingLastModified > localLastModified || incomingPage > localPage {
                    existing.metadata = incomingPDF.metadata
                    existing.isFavorite = incomingPDF.isFavorite
                    existing.collectionId = assignedLocalCollectionID
                    existing.chapters = incomingPDF.chapters
                    existing.lastModified = incomingPDF.lastModified
                    overwrittenMetadataCount += 1
                }
            } else {
                // File exists on the other device, but not locally!
                missingFiles.append(filename)
                
                // Inject placeholder record into SwiftData. It will be downloaded later via P2P.
                let doc = SDConvertedPDF(id: incomingPDF.id, name: incomingPDF.name, url: incomingPDF.url, pageCount: incomingPDF.pageCount, fileSize: incomingPDF.fileSize, metadata: incomingPDF.metadata, collectionId: assignedLocalCollectionID, isFavorite: incomingPDF.isFavorite, isPrivate: incomingPDF.isPrivate, coverImageData: incomingPDF.coverImageData, contentType: incomingPDF.contentType, chapters: incomingPDF.chapters, addedByMode: incomingPDF.addedByMode)
                doc.isOnDevice = false // Cloud/P2P PlaceHolder Flag
                doc.lastModified = incomingPDF.lastModified
                context.insert(doc)
                importedCopiesCount += 1
            }
        }
        
        try context.save()
        
        // Notify the UI to rebuild its groups and arrays
        self.syncStatus = "Reloading Library..."
        NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRescan"), object: nil)
        
        return missingFiles
    }
    
    /// Establishes an authenticated P2P connection to securely stream the Database payload and trigger a merge.
    func fetchAndMerge(from peerIP: String, pin: String) async throws {
        self.isSyncing = true
        self.syncStatus = "Authenticating with \(peerIP)..."
        defer { self.isSyncing = false }
        
        guard let loginURL = URL(string: "http://\(peerIP):8080/login") else { return }
        var loginReq = URLRequest(url: loginURL)
        loginReq.httpMethod = "POST"
        loginReq.httpBody = "pin=\(pin)".data(using: .utf8)
        loginReq.timeoutInterval = 10.0
        
        // 1. Authenticate & Obtain Cookie
        let (_, loginResp) = try await URLSession.shared.data(for: loginReq)
        
        guard let httpLoginResp = loginResp as? HTTPURLResponse else {
             throw NSError(domain: "SyncCoordinator", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid Server Response during Login."])
        }
        
        // WiFiServer sends 302 Found on successful login, 401 on failed PIN.
        if httpLoginResp.statusCode == 401 || httpLoginResp.statusCode == 400 {
            throw NSError(domain: "SyncCoordinator", code: 401, userInfo: [NSLocalizedDescriptionKey: "Incorrect PIN."])
        }
        
        var sessionCookie: String? = nil
        if let setCookieHeader = httpLoginResp.value(forHTTPHeaderField: "Set-Cookie") {
            let parts = setCookieHeader.components(separatedBy: ";")
            for part in parts {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("session=") {
                    sessionCookie = trimmed
                    break
                }
            }
        }
        
        guard let url = URL(string: "http://\(peerIP):8080/api/sync") else {
            throw NSError(domain: "SyncCoordinator", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Peer IP configuration."])
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 45.0 // Wait longer for giant DB exports
        if let cookie = sessionCookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        
        do {
            self.syncStatus = "Downloading Library State..."
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "SyncCoordinator", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid Server Response"])
            }
            
            if httpResponse.statusCode == 200 {
                // Pass directly to the merge engine
                let missingFiles = try await mergeIncomingPayload(data: data)
                
                // Fetch missing physical payloads in background!
                if !missingFiles.isEmpty {
                    Task.detached(priority: .background) {
                        await self.downloadMissingPayloads(missingFiles, from: peerIP, cookie: sessionCookie)
                    }
                }
            } else if httpResponse.statusCode == 401 {
                throw NSError(domain: "SyncCoordinator", code: 401, userInfo: [NSLocalizedDescriptionKey: "Authentication Session Lost. Please retry."])
            } else {
                throw NSError(domain: "SyncCoordinator", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Unexpected Server Error: \(httpResponse.statusCode)"])
            }
        } catch {
            throw error
        }
    }
    
    /// Silent background daemon to fetch the raw physical CBZ files for newly synced placeholder items.
    nonisolated private func downloadMissingPayloads(_ filenames: [String], from peerIP: String, cookie: String?) async {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        
        for filename in filenames {
            // Security: only accept known document extensions to prevent a rogue peer
            // from writing arbitrary files into the app's Documents directory.
            let ext = (filename as NSString).pathExtension.lowercased()
            let allowedExtensions: Set<String> = ["pdf", "epub", "cbz", "cbr", "cbt", "cb7"]
            guard allowedExtensions.contains(ext) else {
                Logger.shared.log("P2P blocked disallowed file type: \(filename)", category: "Network", type: .warning)
                continue
            }
            // Additional guard: reject path components to prevent directory traversal
            guard !filename.contains("/"), !filename.contains("..") else {
                Logger.shared.log("P2P blocked suspicious filename: \(filename)", category: "Network", type: .warning)
                continue
            }

            guard let encodedName = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "http://\(peerIP):8080/\(encodedName)") else { continue }
            
            var request = URLRequest(url: url)
            if let cookie = cookie {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            
            do {
                let (tempURL, response) = try await session.download(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { continue }
                
                let destURL = docDir.appendingPathComponent(filename)
                
                // Safely move file
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destURL)
                
                // Update SwiftData context to flip `isOnDevice` securely
                await MainActor.run {
                    do {
                        let context = InksyncProApp.sharedModelContainer.mainContext
                        let fetchDescriptor = FetchDescriptor<SDConvertedPDF>()
                        let allPDFs = try context.fetch(fetchDescriptor)
                        
                        if let matchedDoc = allPDFs.first(where: { $0.url.lastPathComponent == filename }) {
                            matchedDoc.isOnDevice = true
                            try context.save()
                            NotificationCenter.default.post(name: Notification.Name("LibraryUpdated"), object: nil)
                        }
                    } catch {
                        Logger.shared.log("P2P Background Update Error: \(error)", category: "Network", type: .warning)
                    }
                }
            } catch {
                Logger.shared.log("P2P Payload Fetch failed for \(filename): \(error)", category: "Network", type: .error)
            }
        }
    }
}


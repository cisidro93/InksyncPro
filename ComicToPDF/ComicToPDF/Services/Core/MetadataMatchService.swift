import Foundation
import SwiftData
import SwiftUI
import Combine

@MainActor
class MetadataMatchService: ObservableObject {
    static let shared = MetadataMatchService()
    
    @Published var activeClusters: [SeriesCluster] = []
    @Published var isProcessing: Bool = false
    
    private var modelContext: ModelContext {
        InksyncProApp.sharedModelContainer.mainContext
    }
    
    struct SeriesCluster: Identifiable {
        let id: UUID
        let name: String
        var pdfs: [ConvertedPDF]
        var status: Status
        
        enum Status {
            case idle
            case searching
            case matched(seriesName: String)
            case ambiguous(candidates: [SeriesCandidate])
            case failed(error: String)
        }
    }
    
    struct SeriesCandidate: Identifiable, Codable {
        let id: String
        let name: String
        let startYear: String?
        let publisher: String?
        let coverUrl: String?
    }
    
    private init() {}
    
    // Group files by parent folder or series name
    func rebuildClusters(pdfs: [ConvertedPDF]) {
        var groups: [String: [ConvertedPDF]] = [:]
        for pdf in pdfs {
            let key = pdf.metadata.series?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? pdf.url.deletingLastPathComponent().lastPathComponent
            if !key.isEmpty {
                groups[key, default: []].append(pdf)
            }
        }
        
        self.activeClusters = groups.map { name, issues in
            let status: SeriesCluster.Status
            if issues.contains(where: { $0.metadata.universalSeriesID != nil }) {
                status = .matched(seriesName: name)
            } else {
                status = .idle
            }
            return SeriesCluster(id: UUID(), name: name, pdfs: issues, status: status)
        }.sorted(by: { $0.name < $1.name })
    }
    
    private func updateClusterStatus(clusterID: UUID, status: SeriesCluster.Status) {
        if let idx = activeClusters.firstIndex(where: { $0.id == clusterID }) {
            activeClusters[idx].status = status
        }
    }
    
    // Run throttled matching query on background Task
    func startMatching(clusterID: UUID) async {
        guard let initialIdx = activeClusters.firstIndex(where: { $0.id == clusterID }) else { return }
        activeClusters[initialIdx].status = .searching
        
        let cluster = activeClusters[initialIdx]
        let clusterName = cluster.name
        let clusterPDFs = cluster.pdfs
        
        // 1. Local Metadata Extraction check (ComicInfo.xml / tags)
        for pdf in clusterPDFs {
            if let embedded = try? await extractComicInfoXML(for: pdf) {
                await bindMetadataToCluster(clusterID: clusterID, metadata: embedded)
                return
            }
        }
        
        // 2. ComicVine API Lookup with rate throttling
        do {
            let apiKey = AppSettingsManager.shared.conversionSettings.comicVineAPIKey
            guard !apiKey.isEmpty else {
                updateClusterStatus(clusterID: clusterID, status: .failed(error: "Please enter your ComicVine API Key in Settings."))
                return
            }
            
            // Guideline compliance: enforce throttled delay
            try await Task.sleep(nanoseconds: 2_000_000_000)
            
            let candidates = try await searchSeriesAPI(query: clusterName, apiKey: apiKey)
            
            if candidates.count == 1 {
                await bindCandidateToCluster(clusterID: clusterID, candidate: candidates[0])
            } else if candidates.count > 1 {
                updateClusterStatus(clusterID: clusterID, status: .ambiguous(candidates: candidates))
            } else {
                updateClusterStatus(clusterID: clusterID, status: .failed(error: "No matching series found."))
            }
        } catch {
            updateClusterStatus(clusterID: clusterID, status: .failed(error: error.localizedDescription))
        }
    }
    
    // Bind matching results to SwiftData
    func bindCandidateToCluster(clusterID: UUID, candidate: SeriesCandidate) async {
        guard let idx = activeClusters.firstIndex(where: { $0.id == clusterID }) else { return }
        let cluster = activeClusters[idx]
        let pdfsToUpdate = cluster.pdfs
        
        let descriptor = FetchDescriptor<SDConvertedPDF>()
        guard let allPDFs = try? modelContext.fetch(descriptor) else { return }
        var didSave = false
        
        for pdf in pdfsToUpdate {
            let issueNum = extractIssueNumber(from: pdf.name)
            
            var updatedMetadata = pdf.metadata
            updatedMetadata.universalSeriesID = candidate.id
            updatedMetadata.series = candidate.name
            updatedMetadata.publisher = candidate.publisher
            updatedMetadata.issueNumber = issueNum
            
            if let match = allPDFs.first(where: { $0.id == pdf.id }) {
                match.metadata = updatedMetadata
                didSave = true
            }
        }
        
        if didSave {
            try? modelContext.save()
            NotificationCenter.default.post(name: Notification.Name.NSManagedObjectContextDidSave, object: nil)
        }
        
        // Download and pre-cache mock Character nodes & relationship updates
        await downloadCharacterMap(seriesID: candidate.id, seriesName: candidate.name)
        
        updateClusterStatus(clusterID: clusterID, status: .matched(seriesName: candidate.name))
    }
    
    func bindMetadataToCluster(clusterID: UUID, metadata: PDFMetadata) async {
        guard let idx = activeClusters.firstIndex(where: { $0.id == clusterID }) else { return }
        let cluster = activeClusters[idx]
        let pdfsToUpdate = cluster.pdfs
        let defaultSeriesName = cluster.name
        
        let descriptor = FetchDescriptor<SDConvertedPDF>()
        guard let allPDFs = try? modelContext.fetch(descriptor) else { return }
        var didSave = false
        
        for pdf in pdfsToUpdate {
            var updated = pdf.metadata
            updated.series = metadata.series
            updated.universalSeriesID = metadata.universalSeriesID
            updated.publisher = metadata.publisher
            updated.issueNumber = extractIssueNumber(from: pdf.name)
            
            if let match = allPDFs.first(where: { $0.id == pdf.id }) {
                match.metadata = updated
                didSave = true
            }
        }
        
        if didSave {
            try? modelContext.save()
            NotificationCenter.default.post(name: Notification.Name.NSManagedObjectContextDidSave, object: nil)
        }
        
        updateClusterStatus(clusterID: clusterID, status: .matched(seriesName: metadata.series ?? defaultSeriesName))
    }
    
    private func extractComicInfoXML(for pdf: ConvertedPDF) async throws -> PDFMetadata? {
        // Local ComicInfo.xml extraction stub
        return nil
    }
    
    private func searchSeriesAPI(query: String, apiKey: String) async throws -> [SeriesCandidate] {
        guard !apiKey.isEmpty else { return [] }
        
        // Return simulated candidate list matching the query string
        if query.localizedCaseInsensitiveContains("spider") {
            return [
                SeriesCandidate(id: "1689", name: "The Amazing Spider-Man", startYear: "1963", publisher: "Marvel", coverUrl: nil),
                SeriesCandidate(id: "3482", name: "Spider-Man", startYear: "1999", publisher: "Marvel", coverUrl: nil)
            ]
        } else if query.localizedCaseInsensitiveContains("x-men") {
            return [
                SeriesCandidate(id: "2441", name: "Uncanny X-Men", startYear: "1963", publisher: "Marvel", coverUrl: nil)
            ]
        }
        
        return [
            SeriesCandidate(id: UUID().uuidString, name: query, startYear: "2026", publisher: "Self-Published", coverUrl: nil)
        ]
    }
    
    private func downloadCharacterMap(seriesID: String, seriesName: String) async {
        // Pre-caches series character maps directly to SDCharacterNode and SDRelationship
        // This simulates importing pre-compiled wiki indices for the character overlay.
        let isXMen = seriesName.localizedCaseInsensitiveContains("x-men")
        let isSpider = seriesName.localizedCaseInsensitiveContains("spider")
        
        if isXMen {
            let logan = SDCharacterNode(id: UUID(), name: "Wolverine (Logan)", bio: "Wolverine is a mutant who possesses animal-keen senses, enhanced physical capabilities, and a powerful healing factor.", firstAppearanceIssue: "Incredible Hulk #180")
            let cyclops = SDCharacterNode(id: UUID(), name: "Cyclops (Scott Summers)", bio: "Scott Summers is a mutant leader of the X-Men who can emit powerful beams of energy from his eyes.", firstAppearanceIssue: "X-Men #1")
            let jean = SDCharacterNode(id: UUID(), name: "Jean Grey", bio: "Jean Grey is a mutant telepath and telekinetic who has been host to the powerful Phoenix Force.", firstAppearanceIssue: "X-Men #1")
            
            modelContext.insert(logan)
            modelContext.insert(cyclops)
            modelContext.insert(jean)
            
            // Setup spoiler relationships
            let loveTriangle1 = SDRelationship(sourceCharacterID: logan.id, targetCharacterID: jean.id, type: "Rival / Love Interest", visibleAfterIssueNumber: 1)
            let loveTriangle2 = SDRelationship(sourceCharacterID: cyclops.id, targetCharacterID: jean.id, type: "Husband / Wife", visibleAfterIssueNumber: 5) // Spoiler: lock until issue 5
            let rivals = SDRelationship(sourceCharacterID: logan.id, targetCharacterID: cyclops.id, type: "Teammates / Rivals", visibleAfterIssueNumber: 1)
            
            modelContext.insert(loveTriangle1)
            modelContext.insert(loveTriangle2)
            modelContext.insert(rivals)
            
            // Map character page appearances
            let seriesUUID = UUID(uuidString: "e56bb3f1-f095-4674-a0fa-a10c2834b67d") ?? UUID()
            for page in 2...10 {
                modelContext.insert(SDCharacterAppearance(seriesID: seriesUUID, issueNumber: 1, pageIndex: page, characterID: logan.id))
            }
            for page in 5...12 {
                modelContext.insert(SDCharacterAppearance(seriesID: seriesUUID, issueNumber: 1, pageIndex: page, characterID: cyclops.id))
            }
        } else if isSpider {
            let peter = SDCharacterNode(id: UUID(), name: "Peter Parker (Spider-Man)", bio: "A bite from a radioactive spider gave high school student Peter Parker incredible arachnid-like powers.", firstAppearanceIssue: "Amazing Fantasy #15")
            let mj = SDCharacterNode(id: UUID(), name: "Mary Jane Watson", bio: "Peter Parker's long-time friend, love interest, and eventual wife.", firstAppearanceIssue: "Amazing Spider-Man #42")
            
            modelContext.insert(peter)
            modelContext.insert(mj)
            
            let marriage = SDRelationship(sourceCharacterID: peter.id, targetCharacterID: mj.id, type: "Wife", visibleAfterIssueNumber: 3) // Spoiler: lock until issue 3
            modelContext.insert(marriage)
        }
        
        try? modelContext.save()
        NotificationCenter.default.post(name: Notification.Name.NSManagedObjectContextDidSave, object: nil)
    }
    
    private func extractIssueNumber(from name: String) -> String {
        let pattern = #"\b(?:#|issue\s*)?(\d+)\b"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: name, options: [], range: NSRange(name.startIndex..., in: name)) {
            if let range = Range(match.range(at: 1), in: name) {
                return String(name[range])
            }
        }
        return "1"
    }
}

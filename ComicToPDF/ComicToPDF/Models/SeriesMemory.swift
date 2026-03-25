import Foundation

struct SeriesMemory: Codable {
    var seriesName: String
    var conversionCount: Int = 0
    var lastDeviceID: UUID?
    var confirmedMangaRTL: Bool?
    var averagePanelConfidence: Double?
    var hasUserEverEditedPanels: Bool = false
    var hasUserEverEditedMetadata: Bool = false

    var canSkipImportSheet: Bool {
        conversionCount >= 3
            && confirmedMangaRTL != nil
            && lastDeviceID != nil
            && (averagePanelConfidence ?? 0) >= 0.85
            && !hasUserEverEditedPanels
    }

    var canSuppressPanelReview: Bool {
        conversionCount >= 2
            && (averagePanelConfidence ?? 0) >= 0.85
            && !hasUserEverEditedPanels
    }
}

class SeriesMemoryStore {
    static let shared = SeriesMemoryStore()
    private let key = "seriesMemoryStore_v1"
    private var store: [String: SeriesMemory] = [:]
    private init() { load() }

    func memory(for name: String) -> SeriesMemory? { store[normalise(name)] }

    func record(seriesName: String, deviceID: UUID?, isManga: Bool,
                panelConfidence: Double, editedPanels: Bool, editedMetadata: Bool) {
        let k = normalise(seriesName)
        var m = store[k] ?? SeriesMemory(seriesName: seriesName)
        m.conversionCount += 1
        m.lastDeviceID = deviceID
        m.confirmedMangaRTL = isManga
        if let e = m.averagePanelConfidence { m.averagePanelConfidence = (e + panelConfidence) / 2 }
        else { m.averagePanelConfidence = panelConfidence }
        if editedPanels { m.hasUserEverEditedPanels = true }
        if editedMetadata { m.hasUserEverEditedMetadata = true }
        store[k] = m
        save()
    }

    private func normalise(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func save() {
        if let d = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }
    
    private func load() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode([String: SeriesMemory].self, from: d)
        else { return }
        store = s
    }
}

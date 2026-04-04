import Foundation

/// Defines all global aesthetic, functional, and conversion preferences for the user.
/// Extracted from ConversionManager to isolate App State from background export processing.
@MainActor
class AppSettingsManager: ObservableObject {
    static let shared = AppSettingsManager()
    
    // Core Conversion Options
    @Published var conversionSettings: ConversionSettings
    @Published var conversionPresets: [ConversionPreset]
    
    // Connected Infrastructure
    @Published var kindleDevices: [KindleDevice]
    @Published var sendHistory: [ConvertedPDF]
    
    // Aesthetic & Library State
    @Published var isVaultUnlocked: Bool = false
    
    // ✅ Persistent Watched Folders
    struct WatchedFolder: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        var name: String
        var bookmarkData: Data
    }
    @Published var watchedFolders: [WatchedFolder] = []
    
    private let settingsURL: URL
    
    private init() {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        settingsURL = docDir.appendingPathComponent("inksync_app_settings.json")
        
        self.conversionSettings = ConversionSettings()
        self.conversionPresets = []
        self.kindleDevices = []
        self.sendHistory = []
        
        load()
    }
    
    struct EncodedAppConfiguration: Codable {
        let settings: ConversionSettings
        let presets: [ConversionPreset]
        let devices: [KindleDevice]
        let history: [ConvertedPDF]
        let watchedFolders: [WatchedFolder]?
    }
    
    func load() {
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let config = try? JSONDecoder().decode(EncodedAppConfiguration.self, from: data) else { return }
        
        self.conversionSettings = config.settings
        self.conversionPresets = config.presets
        self.kindleDevices = config.devices
        self.sendHistory = config.history
        self.watchedFolders = config.watchedFolders ?? []
    }
    
    func save() {
        Task.detached(priority: .background) { [weak self] in
            guard let self = self else { return }
            let config = await MainActor.run {
                EncodedAppConfiguration(
                    settings: self.conversionSettings,
                    presets: self.conversionPresets,
                    devices: self.kindleDevices,
                    history: self.sendHistory,
                    watchedFolders: self.watchedFolders
                )
            }
            if let data = try? JSONEncoder().encode(config) {
                try? data.write(to: self.settingsURL, options: .atomic)
            }
        }
    }
    
    // MARK: - Legacy Mutators
    func clearSendHistory() { sendHistory.removeAll(); save() }
    func deletePreset(_ preset: ConversionPreset) { conversionPresets.removeAll { $0.id == preset.id }; save() }
    func savePreset(_ preset: ConversionPreset) { conversionPresets.append(preset); save() }
    func addKindleDevice(_ device: KindleDevice) { kindleDevices.append(device); save() }
    func removeKindleDevice(_ device: KindleDevice) { kindleDevices.removeAll { $0.id == device.id }; save() }
    func updateKindleDevice(_ device: KindleDevice) { if let idx = kindleDevices.firstIndex(where: { $0.id == device.id }) { kindleDevices[idx] = device; save() } }
    func setDefaultKindleDevice(_ device: KindleDevice) { for i in 0..<kindleDevices.count { kindleDevices[i].isDefault = (kindleDevices[i].id == device.id) }; save() }
}

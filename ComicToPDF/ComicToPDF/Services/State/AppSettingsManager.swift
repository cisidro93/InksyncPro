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
    @Published var showSeriesHealthScore: Bool = UserDefaults.standard.bool(forKey: "showSeriesHealthScore")

    // iCloud Sync
    var iCloudSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "iCloudSyncEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "iCloudSyncEnabled") }
    }

    // WiFi Server Security
    var wifiServerHTTPS: Bool {
        get { UserDefaults.standard.object(forKey: "wifiServerHTTPS") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "wifiServerHTTPS") }
    }
    var wifiServerAutoShutdownMinutes: Int {
        get { UserDefaults.standard.object(forKey: "wifiServerAutoShutdownMinutes") as? Int ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: "wifiServerAutoShutdownMinutes") }
    }

    // ✅ Persistent Watched Folders
    struct WatchedFolder: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        var name: String
        var bookmarkData: Data
    }
    @Published var watchedFolders: [WatchedFolder] = []
    
    // ✅ Linked Library: Registered external drives
    struct LinkedDriveEntry: Codable, Identifiable, Sendable {
        var id: UUID = UUID()
        var displayName: String          // e.g. "Samsung T7 — Comics"
        var volumeBookmarkData: Data     // Bookmark to the root folder on the drive
        var lastSeenDate: Date
        var lastSyncedDate: Date?        // Updated each time syncDrive completes
        var fileCount: Int
        var isReadOnly: Bool = false     // Set during initial link probe
    }
    @Published var linkedDrives: [LinkedDriveEntry] = []
    
    private let settingsURL: URL
    
    private init() {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
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
        let linkedDrives: [LinkedDriveEntry]?
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
        self.linkedDrives = config.linkedDrives ?? []
        
        // Start drive monitoring if linked drives exist
        DriveMonitor.shared.startMonitoring(drives: self.linkedDrives)
    }
    
    private var saveTask: Task<Void, Never>?
    
    func save() {
        saveTask?.cancel()
        // Capture settingsURL as a local Sendable value BEFORE entering the
        // detached task. This avoids accessing a MainActor-isolated property
        // from a non-isolated context (Swift 6 strict-concurrency compliance).
        let destinationURL = settingsURL
        saveTask = Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self = self else { return }
            let config = await MainActor.run {
                EncodedAppConfiguration(
                    settings: self.conversionSettings,
                    presets: self.conversionPresets,
                    devices: self.kindleDevices,
                    history: self.sendHistory,
                    watchedFolders: self.watchedFolders,
                    linkedDrives: self.linkedDrives
                )
            }
            if let data = try? JSONEncoder().encode(config) {
                do {
                    try data.write(to: destinationURL, options: .atomic)
                } catch {
                    Logger.shared.log("AppSettingsManager: Failed to write settings — \(error.localizedDescription)", category: "Settings", type: .error)
                }
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
    
    // MARK: - Linked Drive Mutators
    func addLinkedDrive(_ entry: LinkedDriveEntry) {
        linkedDrives.append(entry)
        DriveMonitor.shared.startMonitoring(drives: linkedDrives)
        save()
    }
    
    func removeLinkedDrive(_ entry: LinkedDriveEntry) {
        linkedDrives.removeAll { $0.id == entry.id }
        DriveMonitor.shared.startMonitoring(drives: linkedDrives)
        save()
    }
    
    func updateLinkedDrive(_ entry: LinkedDriveEntry) {
        if let idx = linkedDrives.firstIndex(where: { $0.id == entry.id }) {
            linkedDrives[idx] = entry
            save()
        }
    }
}

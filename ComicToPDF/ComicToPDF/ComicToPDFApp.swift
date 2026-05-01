import SwiftUI
import BackgroundTasks
import SwiftData

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return OrientationLockManager.shared.lockedOrientation
    }
}

@main
struct InksyncProApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    
    // ✅ Global Thread-Safe Model Container
    static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SDConvertedPDF.self,
            SDPDFCollection.self,
            SDRegisteredDevice.self,
            SDAnnotation.self,
            SDPageModel.self,
            SDSeriesMemory.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            print("Could not create ModelContainer: \\(error)")
            do {
                 return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            } catch {
                 fatalError("Could not create Fallback ModelContainer: \\(error)")
            }
        }
    }()
    
    init() {
        // 💥 ANNIHILATE GHOST DATA ON FRESH INSTALLS 💥
        // Guarantees absolute blank UI state if a user deletes and reinstalls the app.
        //
        // SENTINEL STRATEGY: We write a tiny file in Application Support and mark
        // it with the `isExcludedFromBackupKey` attribute so iCloud Drive NEVER
        // syncs or restores it. On a true fresh install this file is absent; on an
        // app-update or first launch after an iCloud restore it is present.
        // This is more reliable than UserDefaults alone, which can be restored by
        // iCloud Backup (NSUbiquitousKeyValueStore) on some device configurations.
        
        let fileManager = FileManager.default
        let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        
        // Sentinel lives in Application Support — excluded from backup so it cannot
        // ever travel with an iCloud restore of the database.
        let sentinelURL = supportDir.appendingPathComponent(".inksync_install_sentinel_v1", isDirectory: false)
        let sentinelExists = fileManager.fileExists(atPath: sentinelURL.path)
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        let isNotFreshInstall = UserDefaults.standard.bool(forKey: "isNotFreshInstall_v3")
        
        let shouldNuke: Bool
        if sentinelExists {
            // Sentinel is present — this is either an update or a normal re-launch.
            // NEVER nuke an existing user's library.
            shouldNuke = false
        } else if hasCompletedOnboarding || isNotFreshInstall {
            // No sentinel but UserDefaults says this isn't a fresh install.
            // This happens after an iCloud-restored database lands on a device where
            // the user deleted and reinstalled: UserDefaults was restored along with
            // the iCloud backup. Trust the sentinel absence and treat as fresh.
            // EXCEPTION: if onboarding was completed we MUST preserve the library.
            if hasCompletedOnboarding {
                // Genuine existing user — just write the sentinel and move on.
                shouldNuke = false
            } else {
                // isNotFreshInstall was set but sentinel is absent — ghost restore.
                // Nuke to clear any iCloud-restored database rows.
                shouldNuke = true
            }
        } else {
            // Neither sentinel nor onboarding flag — true first launch after a clean install.
            shouldNuke = true
        }
        
        if shouldNuke {
            // 1. Vaporize Documents Directory Contents (Nukes all ghost CBZs automatically synced by iCloud)
            if let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                if let items = try? fileManager.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) {
                    for item in items { try? fileManager.removeItem(at: item) }
                }
            }
            
            // 2. Vaporize Application Support Directory Contents
            //    This removes the SwiftData SQLite vault, cover image cache, etc.
            //    The sentinel file doesn't exist yet so nothing to skip here.
            if let items = try? fileManager.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
                for item in items {
                    // Skip the sentinel itself — it shouldn't exist yet but be safe.
                    if item.lastPathComponent.hasPrefix(".inksync_install_sentinel") { continue }
                    try? fileManager.removeItem(at: item)
                }
            }
            
            Logger.shared.log("InksyncProApp: Fresh install nuke complete. Ghost data eradicated.", category: "Migration", type: .warning)
        }
        
        // Write (or re-write) the sentinel after every launch so it is always present
        // for the lifetime of the install. The file content is irrelevant; existence is the signal.
        if !fileManager.fileExists(atPath: sentinelURL.path) {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            try? timestamp.write(to: sentinelURL, atomically: true, encoding: .utf8)
            // Crucially, exclude from iCloud / iTunes backup so it is NEVER restored.
            // URL is a value type — setResourceValues is mutating, so we need a var copy.
            var mutableSentinelURL = sentinelURL
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? mutableSentinelURL.setResourceValues(resourceValues)
        }
        
        // Keep the legacy UserDefaults flag set for backwards compatibility with any code
        // that may still read it.
        if !isNotFreshInstall {
            UserDefaults.standard.set(true, forKey: "isNotFreshInstall_v3")
        }
        
        // Register Background Task for Auto-Sync
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.antigravity.InksyncPro.autosync", using: nil) { task in
            InksyncProApp.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }
    
    var body: some Scene {
        WindowGroup { 
            ContentView()
                // ✅ SwiftData Engine Attachment (Injected globally)
                .modelContainer(InksyncProApp.sharedModelContainer)
                .onAppear {
                    Task { @MainActor in
                        // Context is automatically available in views, but we can't easily grab it inside WindowGroup without a local view wrapper. 
                        // MigrationService call will be placed inside ContentView's onAppear to guarantee environment context.
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background, .inactive:
                         SecurityManager.shared.handleAppBackgrounding()
                         // Whenever the app goes to the background, we schedule the next sync
                         InksyncProApp.scheduleAppRefresh()
                    case .active:
                         SecurityManager.shared.handleAppForegrounding()
                    @unknown default: break
                    }
                }
                // ✅ Phase 5: Apple Handoff (Reader State Sync)
                .onContinueUserActivity("com.inksync.read") { userActivity in
                    if let pdfIDString = userActivity.userInfo?["pdfID"] as? String,
                       let pdfID = UUID(uuidString: pdfIDString),
                       let pageIndex = userActivity.userInfo?["pageIndex"] as? Int {
                        // We fire a Notification so the ModernLibraryView/Router can intercept it
                        // and throw up the specific PDF automatically.
                        NotificationCenter.default.post(
                            name: NSNotification.Name("HandoffRequested"),
                            object: nil,
                            userInfo: ["pdfID": pdfID, "pageIndex": pageIndex]
                        )
                    }
                }
        }
    }
    
    // MARK: - Background Sync Logic
    
    static func handleAppRefresh(task: BGAppRefreshTask) {
        // As per Apple Guidelines, immediately schedule the NEXT occurrence
        InksyncProApp.scheduleAppRefresh()
        
        let operation = Task {
            await CloudSyncManager.shared.performSync()
        }
        
        task.expirationHandler = {
            operation.cancel()
        }
        
        Task {
            _ = await operation.result
            task.setTaskCompleted(success: !operation.isCancelled)
        }
    }
    
    static func scheduleAppRefresh() {
        guard UserDefaults.standard.bool(forKey: "enableBackgroundSync") else { return }
        
        let request = BGAppRefreshTaskRequest(identifier: "com.antigravity.InksyncPro.autosync")
        // Fetch no earlier than 15 minutes from now to respect system power and limits
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            Logger.shared.log("BGTaskScheduler: AutoSync scheduled successfully.", category: "Cloud")
        } catch {
            Logger.shared.log("BGTaskScheduler: Could not schedule app refresh — \(error.localizedDescription)", category: "Cloud", type: .warning)
        }
    }
}

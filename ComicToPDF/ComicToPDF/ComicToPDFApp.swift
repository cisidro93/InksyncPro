import SwiftUI
import BackgroundTasks
import SwiftData

@main
struct InksyncProApp: App {
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
        // We use UserDefaults here because standard UserDefaults are wiped on app deletion
        // but reliably persist across app updates, ensuring we never wipe an existing user's library
        // when they update the app.
        
        let fileManager = FileManager.default
        let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        let isNotFreshInstall = UserDefaults.standard.bool(forKey: "isNotFreshInstall_v3")
        
        // If they have completed onboarding from a previous version, or we already marked it as not fresh:
        if !hasCompletedOnboarding && !isNotFreshInstall {
            Task.detached(priority: .background) {
                // 1. Vaporize Documents Directory Contents (Nukes all ghost CBZs automatically synced by iCloud)
                if let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                    if let items = try? fileManager.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) {
                        for item in items { try? fileManager.removeItem(at: item) }
                    }
                }
                
                // 2. Vaporize Application Support Directory Contents (Nukes legacy SwiftData SQLite vaults and stored Covers)
                if let items = try? fileManager.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
                    for item in items { 
                        if item.lastPathComponent.hasPrefix(".hasEmployedFreshInstallNuke") { continue }
                        try? fileManager.removeItem(at: item) 
                    }
                }
            }
            // Mark as not fresh so subsequent launches don't nuke
            UserDefaults.standard.set(true, forKey: "isNotFreshInstall_v3")
        } else if !isNotFreshInstall {
            // User had completed onboarding before we added this specific flag,
            // so we definitely shouldn't nuke. Just set the flag.
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

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
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    init() {
        // ?? ANNIHILATE GHOST DATA ON FRESH INSTALLS ??
        // Guarantees absolute blank UI state if a user deletes and reinstalls the app.
        // Bypasses Simulator cache retentions, Sideloadly hot-swaps, and iCloud Document injections.
        if !UserDefaults.standard.bool(forKey: "hasEmployedFreshInstallNuke_v1") {
            let fileManager = FileManager.default
            
            // 1. Vaporize Documents Directory (Nukes all ghost CBZs automatically synced by iCloud)
            if let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? fileManager.removeItem(at: docDir)
                try? fileManager.createDirectory(at: docDir, withIntermediateDirectories: true, attributes: nil)
            }
            
            // 2. Vaporize Application Support Directory (Nukes legacy SwiftData SQLite vaults and stored Covers)
            if let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                try? fileManager.removeItem(at: supportDir)
                try? fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true, attributes: nil)
            }
            
            UserDefaults.standard.set(true, forKey: "hasEmployedFreshInstallNuke_v1")
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
                    // Trigger Migration asynchronously if on iOS 18 simulator
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

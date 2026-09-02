import SwiftUI
import BackgroundTasks
import SwiftData
import CoreSpotlight

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return OrientationLockManager.shared.lockedOrientation
    }

    // MARK: - URL Open Handler
    //
    // This is the guaranteed entry point for ALL custom-scheme and file-URL opens,
    // regardless of whether SwiftUI's onOpenURL fires (it sometimes doesn't on iPad
    // multi-window or when the app is already active).
    //
    // Pattern:
    //   inksyncpro://shared-import  ← Share Extension triggered open
    //   file://...                  ← "Open With" / Files.app / AirDrop
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        Task { @MainActor in
            await SharedImportCoordinator.shared.handleIncomingURL(url)
        }
        return true
    }

    // MARK: - Background URLSession (OPDSDownloadQueue)
    // Required so OPDSDownloadQueue's background download session receives its
    // completion handler when the system wakes the app post-download.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == "com.inksyncpro.opds.dl" {
            OPDSDownloadQueue.shared.handleBackgroundEvents(completionHandler: completionHandler)
        } else {
            completionHandler()
        }
    }
}

@main
struct InksyncProApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    
    // ✅ Global Thread-Safe Model Container
    nonisolated static let sharedModelContainer: ModelContainer = {
        // Ensure nuke guard runs BEFORE the container is initialized and locks SQLite files
        InstallGuardService.shared.executeGuard()
        
        let schema = Schema([
            SDConvertedPDF.self,
            SDPDFCollection.self,
            SDRegisteredDevice.self,
            SDAnnotation.self,
            SDPageModel.self,
            SDSeriesMemory.self,
            SDManuscriptProject.self,
            SDManuscriptDocument.self,
            SDOPDSServer.self,
            SDNotebook.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        
        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            return container
        } catch {
            print("Could not create ModelContainer: \(error)")
            do {
                 let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
                 return container
            } catch {
                 fatalError("Could not create Fallback ModelContainer: \(error)")
            }
        }
    }()
    
    init() {
        // Ignore SIGPIPE to prevent socket/descriptor write failures from crashing the app
        signal(SIGPIPE, SIG_IGN)
        
        // 💥 ANNIHILATE GHOST DATA ON FRESH INSTALLS 💥
        InstallGuardService.shared.executeGuard()
        
        // Purge orphaned extraction temp directories from previous sessions / crashes
        InksyncProApp.purgeOrphanedTempDirs()
        
        // Register Background Task for Auto-Sync
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.antigravity.InksyncPro.autosync", using: nil) { task in
            if let refreshTask = task as? BGAppRefreshTask {
                InksyncProApp.handleAppRefresh(task: refreshTask)
            } else {
                task.setTaskCompleted(success: false)
            }
        }
    }
    
    @AppStorage("selectedTheme") private var selectedTheme: AppearanceMode = .system
    
    var body: some Scene {
        WindowGroup { 
            ContentView()
                // ✅ SwiftData Engine Attachment (Injected globally)
                .modelContainer(InksyncProApp.sharedModelContainer)
                .preferredColorScheme(selectedTheme.colorScheme)
                .onAppear {
                    // Inject ConversionManager into SharedImportCoordinator on app launch
                    if let manager = ConversionManager.shared {
                        SharedImportCoordinator.shared.conversionManager = manager
                    }
                    // Check for any pending imports from Share Extension on launch
                    SharedImportCoordinator.shared.coordinateImport(retryCount: 4, retryDelaySeconds: 0.5)
                }
                .onOpenURL { incomingURL in
                    Logger.shared.log("InksyncProApp: Received incoming open URL: \(incomingURL.absoluteString)", category: "System")
                    Task { @MainActor in
                        await SharedImportCoordinator.shared.handleIncomingURL(incomingURL)
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background, .inactive:
                         SecurityManager.shared.handleAppBackgrounding()
                         DatabaseBackupService.shared.performBackup()
                         // Whenever the app goes to the background, we schedule the next sync
                         InksyncProApp.scheduleAppRefresh()
                    case .active:
                         SecurityManager.shared.handleAppForegrounding()
                         SharedImportCoordinator.shared.coordinateImport(retryCount: 3, retryDelaySeconds: 0.5)
                         NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil)
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
                            name: .handoffRequested,
                            object: nil,
                            userInfo: ["pdfID": pdfID, "pageIndex": pageIndex]
                        )
                    }
                }
                // ✅ Spotlight integration deep-linking handlers
                .onContinueUserActivity(CSSearchableItemActionType) { userActivity in
                    guard let uniqueID = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                    if uniqueID.hasPrefix("book-") {
                        let parts = uniqueID.components(separatedBy: "-page-")
                        let pdfIDString = parts[0].replacingOccurrences(of: "book-", with: "")
                        guard let pdfID = UUID(uuidString: pdfIDString) else { return }
                        let pageIndex = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
                        NotificationCenter.default.post(
                            name: .handoffRequested,
                            object: nil,
                            userInfo: ["pdfID": pdfID, "pageIndex": pageIndex]
                        )
                    } else if uniqueID.hasPrefix("ann-") {
                        let annIDString = uniqueID.replacingOccurrences(of: "ann-", with: "")
                        guard let annotationID = UUID(uuidString: annIDString) else { return }
                        Task { @MainActor in
                            let annotations = AnnotationStore.shared.allAnnotations
                            if let target = annotations.first(where: { $0.id == annotationID }) {
                                NotificationCenter.default.post(
                                    name: .handoffRequested,
                                    object: nil,
                                    userInfo: ["pdfID": target.pdfID, "pageIndex": target.pageIndex]
                                )
                            }
                        }
                    }
                }
                .onContinueUserActivity(SpotlightIndexer.openBookActivityType) { userActivity in
                    if let pdfIDString = userActivity.userInfo?["pdfID"] as? String,
                       let pdfID = UUID(uuidString: pdfIDString) {
                        let pageIndex = userActivity.userInfo?["pageIndex"] as? Int ?? 0
                        NotificationCenter.default.post(
                            name: .handoffRequested,
                            object: nil,
                            userInfo: ["pdfID": pdfID, "pageIndex": pageIndex]
                        )
                    }
                }
                .onContinueUserActivity(SpotlightIndexer.openAnnotationActivityType) { userActivity in
                    if let annotationIDString = userActivity.userInfo?["annotationID"] as? String,
                       let annotationID = UUID(uuidString: annotationIDString) {
                        Task { @MainActor in
                            let annotations = AnnotationStore.shared.allAnnotations
                            if let target = annotations.first(where: { $0.id == annotationID }) {
                                NotificationCenter.default.post(
                                    name: .handoffRequested,
                                    object: nil,
                                    userInfo: ["pdfID": target.pdfID, "pageIndex": target.pageIndex]
                                )
                            }
                        }
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
    
    static func purgeOrphanedTempDirs() {
        Task.detached(priority: .background) {
            let fm = FileManager.default
            let tempDir = fm.temporaryDirectory
            guard let urls = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) else {
                return
            }
            for url in urls {
                let name = url.lastPathComponent
                if name.hasPrefix("cbr_") || name.hasPrefix("cbt_") {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }
}

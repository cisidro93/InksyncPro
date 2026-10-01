import SwiftUI
import BackgroundTasks
import SwiftData
import CoreSpotlight
import AVFoundation

class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Guarantee app default audio session is ambient + mixWithOthers so background audio (Spotify, Apple Music, podcasts) is NEVER interrupted.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        // Dynamically register any downloaded custom fonts with CoreText
        CustomFontManager.shared.registerInstalledFonts()
        return true
    }

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
        Logger.shared.log("AppDelegate: Received incoming open URL: \(url.absoluteString)", category: "System")
        if let destination = UniversalLinkBridge.shared.parse(url: url) {
            Task { @MainActor in
                UniversalLinkBridge.shared.handleDeepLink(destination)
            }
            return true
        }
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

    // MARK: - iPadOS Hardware Keyboard Shortcuts HUD (⌘ held down)
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }

        let makeCmd: (String, UIKeyModifierFlags, Selector, String) -> UIKeyCommand = { input, flags, action, title in
            let cmd = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
            cmd.discoverabilityTitle = title
            return cmd
        }

        // Library Shortcuts Menu
        let libraryCommands = [
            makeCmd("o", .command, #selector(handleImportQueue(_:)), "Import Queue / Books..."),
            makeCmd("l", .command, #selector(handleLinkDrive(_:)), "Link External Drive..."),
            makeCmd("f", .command, #selector(handleFocusSearch(_:)), "Search Library"),
            makeCmd("1", .command, #selector(handleShelfAll(_:)), "All Books Shelf"),
            makeCmd("2", .command, #selector(handleShelfComics(_:)), "Comics Shelf"),
            makeCmd("3", .command, #selector(handleShelfBooks(_:)), "Books & EPUB Shelf"),
            makeCmd("4", .command, #selector(handleShelfDrive(_:)), "External Drive Shelf"),
            makeCmd("/", .command, #selector(handleShowShortcutsSheet(_:)), "Keyboard Shortcuts Cheat Sheet")
        ]
        let libraryMenu = UIMenu(title: "Library", children: libraryCommands)

        // Reader Shortcuts Menu
        let readerCommands = [
            makeCmd("]", .command, #selector(handleReaderNextPage(_:)), "Next Page (Split-Notebook Safe)"),
            makeCmd("[", .command, #selector(handleReaderPrevPage(_:)), "Previous Page (Split-Notebook Safe)"),
            makeCmd("d", .command, #selector(handleToggleDualPage(_:)), "Toggle Dual Page Spread"),
            makeCmd("m", .command, #selector(handleToggleSmartCrop(_:)), "Toggle Smart Margin Crop"),
            makeCmd("h", .command, #selector(handleHighlightSelection(_:)), "Stylus Highlighter Mode"),
            makeCmd("/", .command, #selector(handleShowShortcutsSheet(_:)), "Keyboard Shortcuts Cheat Sheet")
        ]
        let readerMenu = UIMenu(title: "Reader", children: readerCommands)

        // Study Notebook Menu
        let notebookCommands = [
            makeCmd("n", .command, #selector(handleToggleStudyNotebook(_:)), "Toggle Study Notebook"),
            makeCmd("p", .command, #selector(handleStampPageLink(_:)), "Stamp Current Page Link"),
            makeCmd("v", [.command, .alternate], #selector(handlePasteQuoteToNotebook(_:)), "Paste Quote into Notebook"),
            makeCmd("d", [.command, .alternate], #selector(handlePasteMetabolizedDialectic(_:)), "Metabolize as Dialectic Triad"),
            makeCmd("r", [.command, .alternate], #selector(handleToggleRecitationCurtain(_:)), "Toggle Recall Recitation Curtain"),
            makeCmd("s", .command, #selector(handleSaveNotes(_:)), "Save Notes")
        ]
        let notebookMenu = UIMenu(title: "Study Notebook", children: notebookCommands)

        if builder.menu(for: .file) != nil {
            builder.insertSibling(libraryMenu, afterMenu: .file)
        } else {
            builder.insertChild(libraryMenu, atStartOfMenu: .root)
        }
        builder.insertChild(readerMenu, atEndOfMenu: .root)
        builder.insertChild(notebookMenu, atEndOfMenu: .root)
    }

    @objc func handleImportQueue(_ sender: Any?) {
        AppRouter.shared.presentSheet(.importQueue)
    }
    @objc func handleLinkDrive(_ sender: Any?) {
        NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.linkDriveRequested"), object: nil)
    }
    @objc func handleFocusSearch(_ sender: Any?) {
        NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.focusSearch"), object: nil)
    }
    @objc func handleShelfAll(_ sender: Any?) {
        NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.switchShelf"), object: nil, userInfo: ["shelf": "all"])
    }
    @objc func handleShelfComics(_ sender: Any?) {
        NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.switchShelf"), object: nil, userInfo: ["shelf": "comics"])
    }
    @objc func handleShelfBooks(_ sender: Any?) {
        NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.switchShelf"), object: nil, userInfo: ["shelf": "books"])
    }
    @objc func handleShelfDrive(_ sender: Any?) {
        NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.switchShelf"), object: nil, userInfo: ["shelf": "onDrive"])
    }

    @objc func handleReaderNextPage(_ sender: Any?) {
        NotificationCenter.default.post(name: NSNotification.Name("ReaderAdvancePageForward"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.readerNextPage"), object: nil)
    }
    @objc func handleReaderPrevPage(_ sender: Any?) {
        NotificationCenter.default.post(name: NSNotification.Name("ReaderAdvancePageBackward"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.readerPrevPage"), object: nil)
    }
    @objc func handleToggleDualPage(_ sender: Any?) { NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.toggleDualPage"), object: nil) }
    @objc func handleToggleSmartCrop(_ sender: Any?) { NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.toggleSmartCrop"), object: nil) }
    @objc func handleHighlightSelection(_ sender: Any?) {
        NotificationCenter.default.post(name: NSNotification.Name("ReaderToggleHighlighterMode"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.highlightSelection"), object: nil)
    }
    @objc func handleToggleStudyNotebook(_ sender: Any?) { NotificationCenter.default.post(name: .toggleStudyNotebook, object: nil) }
    @objc func handleStampPageLink(_ sender: Any?) { NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.stampPageLink"), object: nil) }
    @objc func handlePasteQuoteToNotebook(_ sender: Any?) { NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.pasteQuoteToNotebook"), object: nil) }
    @objc func handlePasteMetabolizedDialectic(_ sender: Any?) { NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.pasteMetabolizedDialectic"), object: nil) }
    @objc func handleToggleRecitationCurtain(_ sender: Any?) { NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.toggleRecitationCurtain"), object: nil) }
    @objc func handleSaveNotes(_ sender: Any?) { NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.saveNotes"), object: nil) }
    @objc func handleShowShortcutsSheet(_ sender: Any?) { NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.showShortcutsSheet"), object: nil) }
}

@main
struct InksyncProApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    
    // ✅ Global Thread-Safe Model Container
    nonisolated static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SDConvertedPDF.self,
            SDPDFCollection.self,
            SDRegisteredDevice.self,
            SDAnnotation.self,
            SDPageModel.self,
            SDSeriesMemory.self,
            SDManuscriptProject.self,
            SDManuscriptDocument.self,
            SDHoldingTrayItem.self,
            SDOPDSServer.self,
            SDNotebook.self,
            SDVocabularyWord.self
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
        
        // Dynamically register installed custom fonts
        CustomFontManager.shared.registerInstalledFonts()
    }
    
    @AppStorage("selectedTheme") private var selectedTheme: AppearanceMode = .system
    static var lastForegroundScanTimestamp: Date = Date()
    
    var body: some Scene {
        WindowGroup { 
            ContentView()
                // ✅ SwiftData Engine Attachment (Injected globally)
                .modelContainer(InksyncProApp.sharedModelContainer)
                .preferredColorScheme(selectedTheme.colorScheme)
                .environmentObject(ConversionManager.shared)
                .environmentObject(AppSettingsManager.shared)
                .onAppear {
                    // Inject ConversionManager into SharedImportCoordinator on app launch
                    SharedImportCoordinator.shared.conversionManager = ConversionManager.shared
                    // Check for any pending imports from Share Extension on launch if already bootstrapped and pending
                    if LibraryService.shared.hasBootstrapped && SharedImportCoordinator.shared.hasPendingShareImport() {
                        SharedImportCoordinator.shared.coordinateImport(retryCount: 4, retryDelaySeconds: 0.5)
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                         SecurityManager.shared.handleAppBackgrounding()
                         DatabaseBackupService.shared.performBackup()
                         // Whenever the app goes to the background, we schedule the next sync
                         InksyncProApp.scheduleAppRefresh()
                         // Proactive Jetsam Defense: evict volatile in-memory decompressed textures
                         Task {
                             await JITComicCacheEngine.shared.handleBackgroundPurge()
                             await ReaderImageFilterEngine.shared.purgeCache()
                         }
                    case .inactive:
                         // Transitional state (e.g. Control Center, Notification Center, system alerts)
                         break
                    case .active:
                         SecurityManager.shared.handleAppForegrounding()
                         if LibraryService.shared.hasBootstrapped && SharedImportCoordinator.shared.hasPendingShareImport() {
                             SharedImportCoordinator.shared.coordinateImport(retryCount: 3, retryDelaySeconds: 0.5)
                         } else {
                             // Throttle routine foreground rescans: at least 30s must elapse to prevent
                             // thrashing disk enumerators and rebuilding caches on simple app switches.
                             let now = Date()
                             if now.timeIntervalSince(InksyncProApp.lastForegroundScanTimestamp) >= 30.0 {
                                 InksyncProApp.lastForegroundScanTimestamp = now
                                 NotificationCenter.default.post(name: .libraryNeedsRescan, object: nil)
                             }
                         }
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
                .onOpenURL { url in
                    Logger.shared.log("InksyncProApp: onOpenURL received '\(url.absoluteString)'", category: "System", type: .info)
                    Task { @MainActor in
                        await SharedImportCoordinator.shared.handleIncomingURL(url)
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Queue / Books...") {
                    AppRouter.shared.presentSheet(.importQueue)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Link External Drive...") {
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.linkDriveRequested"), object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command])
            }

            CommandMenu("Library") {
                Button("Search Library") {
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.focusSearch"), object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("All Books Shelf") {
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.switchShelf"), object: nil, userInfo: ["shelf": "all"])
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Comics Shelf") {
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.switchShelf"), object: nil, userInfo: ["shelf": "comics"])
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("Books & EPUB Shelf") {
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.switchShelf"), object: nil, userInfo: ["shelf": "books"])
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button("External Drive Shelf") {
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.switchShelf"), object: nil, userInfo: ["shelf": "onDrive"])
                }
                .keyboardShortcut("4", modifiers: [.command])

                Button("Keyboard Shortcuts Cheat Sheet") {
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.showShortcutsSheet"), object: nil)
                }
                .keyboardShortcut("/", modifiers: [.command])
            }

            CommandMenu("Reader") {
                Button("Next Page (Split-Notebook Safe)") {
                    NotificationCenter.default.post(name: NSNotification.Name("ReaderAdvancePageForward"), object: nil)
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.readerNextPage"), object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command])

                Button("Previous Page (Split-Notebook Safe)") {
                    NotificationCenter.default.post(name: NSNotification.Name("ReaderAdvancePageBackward"), object: nil)
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.readerPrevPage"), object: nil)
                }
                .keyboardShortcut("[", modifiers: [.command])

                Button("Toggle Dual Page Spread") {
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.toggleDualPage"), object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Toggle Smart Margin Crop") {
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.toggleSmartCrop"), object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command])

                Button("Stylus Highlighter Mode") {
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.highlightSelection"), object: nil)
                }
                .keyboardShortcut("h", modifiers: [.command])
            }

            CommandMenu("Study Notebook") {
                Button("Toggle Study Notebook") {
                    NotificationCenter.default.post(name: .toggleStudyNotebook, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Stamp Current Page Link") {
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.stampPageLink"), object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command])

                Button("Paste Quote into Notebook") {
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.pasteQuoteToNotebook"), object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .option])

                Button("Metabolize as Dialectic Triad") {
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.pasteMetabolizedDialectic"), object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .option])

                Button("Toggle Recall Recitation Curtain") {
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.toggleRecitationCurtain"), object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .option])

                Button("Save Notes") {
                    NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.saveNotes"), object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command])
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

import SwiftUI

@MainActor
class AppRouter: ObservableObject {
    static let shared = AppRouter()
    
    @Published var activeSheet: LibrarySheetDestination?
    @Published var activeFullScreen: LibraryFullScreenDestination?
    
    // Global Navigation Path for NavigationStack
    @Published var path = NavigationPath()
    
    @Published var selectedTab: Int = 0
    
    func presentSheet(_ sheet: LibrarySheetDestination) {
        Logger.shared.log("AppRouter: presentSheet(\(sheet))", category: "Navigation", type: .info)
        activeSheet = sheet
    }
    
    func presentFullScreen(_ screen: LibraryFullScreenDestination) {
        Logger.shared.log("AppRouter: presentFullScreen(\(screen))", category: "Navigation", type: .info)
        activeFullScreen = screen
    }
    
    func dismissSheet() {
        Logger.shared.log("AppRouter: dismissSheet", category: "Navigation", type: .info)
        activeSheet = nil
    }
    
    func dismissFullScreen() {
        Logger.shared.log("AppRouter: dismissFullScreen", category: "Navigation", type: .info)
        activeFullScreen = nil
    }
    
    func popToRoot() {
        Logger.shared.log("AppRouter: popToRoot (removing \(path.count) items)", category: "Navigation", type: .info)
        path.removeLast(path.count)
    }
}

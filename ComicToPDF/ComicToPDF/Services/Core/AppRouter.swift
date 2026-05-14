import SwiftUI

@MainActor
class AppRouter: ObservableObject {
    static let shared = AppRouter()
    
    @Published var activeSheet: LibrarySheetDestination?
    @Published var activeFullScreen: LibraryFullScreenDestination?
    
    // Global Navigation Path for NavigationStack
    @Published var path = NavigationPath()
    
    func presentSheet(_ sheet: LibrarySheetDestination) {
        activeSheet = sheet
    }
    
    func presentFullScreen(_ screen: LibraryFullScreenDestination) {
        activeFullScreen = screen
    }
    
    func dismissSheet() {
        activeSheet = nil
    }
    
    func dismissFullScreen() {
        activeFullScreen = nil
    }
    
    func popToRoot() {
        path.removeLast(path.count)
    }
}

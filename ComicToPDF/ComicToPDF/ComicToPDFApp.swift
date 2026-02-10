import SwiftUI

@main
struct InksyncProApp: App {
    var body: some Scene {
        WindowGroup { 
            ContentView()
                .environmentObject(ConversionManager())
        }
    }
}

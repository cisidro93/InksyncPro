import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        Form {
            Section {
                Text("Settings")
            } header: {
                Text("General")
            }
        }
        .navigationTitle("Settings")
    }
}

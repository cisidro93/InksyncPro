import SwiftUI

struct AdvancedOptionsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    
    var body: some View {
        Form {
            Section {
                // Fixed header syntax:
                Toggle(isOn: $conversionManager.conversionSettings.enablePanelSplit) {
                    Text("Enable Panel Split")
                }
            } header: {
                Text("Panel Processing")
            }
        }
        .navigationTitle("Advanced Options")
    }
}

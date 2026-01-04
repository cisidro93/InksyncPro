import SwiftUI

struct AdvancedOptionsView: View {
    @EnvironmentObject var conversionManager: ConversionManager

    var body: some View {
        Form {
            // Panel Processing Section
            Section(header: Text("Panel Processing")) {
                Toggle(isOn: $conversionManager.conversionSettings.enablePanelSplit) {
                    VStack(alignment: .leading) {
                        Text("Split Double-Page Spreads")
                            .font(.headline)
                        Text("Automatically splits wide landscape images into two portrait pages.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                
                if conversionManager.conversionSettings.enablePanelSplit {
                    Toggle(isOn: $conversionManager.conversionSettings.mangaMode) {
                        VStack(alignment: .leading) {
                            Text("Manga Mode (Right-to-Left)")
                            Text("Process and split pages for right-to-left reading order.")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
            
            Section(footer: Text("These settings apply to all new conversions.")) {
                // Placeholder for future advanced options
            }
        }
        .navigationTitle("Advanced Options")
    }
}

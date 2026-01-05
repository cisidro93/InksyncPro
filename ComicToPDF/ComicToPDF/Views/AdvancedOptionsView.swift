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
                
                // ✅ KEYWORD: Kindle Optimization
                Toggle(isOn: $conversionManager.conversionSettings.epubSettings.splitPanels) {
                    VStack(alignment: .leading) {
                        Text("Optimize for Kindle")
                        Text("Physically splits detected panels into separate pages for better reading on E-Ink.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .onChange(of: conversionManager.conversionSettings.epubSettings.splitPanels) { newValue in
                    if newValue {
                         conversionManager.conversionSettings.epubSettings.enablePanelView = false
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

import SwiftUI

struct ConvertView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var settings = ConversionSettings()
    @State private var showSuccess = false
    
    var body: some View {
        Form {
            Section(header: Text("Output")) {
                Picker("Format", selection: $settings.outputFormat) {
                    ForEach(OutputFormat.allCases) { format in
                        Label(format.rawValue, systemImage: format.icon).tag(format)
                    }
                }
                
                Picker("Quality", selection: $settings.compressionQuality) {
                    ForEach(CompressionPreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
            }
            
            Section(header: Text("Panel Processing")) {
                Toggle("Enable Panel Split", isOn: $settings.enablePanelSplit)
                
                if settings.enablePanelSplit {
                    Picker("Detection Mode", selection: $settings.epubSettings.panelDetectionMode) {
                        Text("Automatic").tag(PanelExtractor.ExtractionMode.automatic)
                        // ✅ Fix: Use the static constant we just added
                        Text("2x2 Grid").tag(PanelExtractor.ExtractionMode.grid2x2)
                    }
                }
            }
            
            Section(header: Text("Actions")) {
                Button("Save Settings") {
                    conversionManager.conversionSettings = settings
                    conversionManager.saveSettings()
                }
                
                Button("Convert Library") {
                    Task {
                        // Logic stub
                    }
                }
            }
        }
        .onAppear {
            settings = conversionManager.conversionSettings
        }
        .navigationTitle("Convert")
    }
}

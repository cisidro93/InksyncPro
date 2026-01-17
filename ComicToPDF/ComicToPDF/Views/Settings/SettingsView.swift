import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingAddDevice = false
    @State private var showingDeleteAlert = false
    @State private var deviceToDelete: KindleDevice?
    
    var body: some View {
        Form {
            Section(header: Text("General")) {
                Picker("Output Format", selection: $conversionManager.conversionSettings.outputFormat) {
                    ForEach(OutputFormat.allCases) { format in
                        Label(format.rawValue, systemImage: format.icon).tag(format)
                    }
                }
            }
            
            Section(header: Text("Optimization")) {
                Picker("Compression", selection: $conversionManager.conversionSettings.compressionQuality) {
                    ForEach(CompressionPreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                
                Picker("Auto-Split Files", selection: $conversionManager.conversionSettings.splitMode) {
                    ForEach(FileSizeSplitMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                Text(conversionManager.conversionSettings.splitMode.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // ✅ NEW: Panel Strategy Picker
                if conversionManager.conversionSettings.enablePanelSplit {
                    Divider()
                    
                    Picker("Panel Strategy", selection: $conversionManager.conversionSettings.panelStrategy) {
                        ForEach(PanelStrategy.allCases) { strategy in
                            Text(strategy.rawValue).tag(strategy)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    // Helper text to educate the user
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle").font(.caption)
                        Text(conversionManager.conversionSettings.panelStrategy.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Section(header: Text("Kindle & E-Reader")) {
                Toggle("Optimize for Device", isOn: $conversionManager.conversionSettings.optimizeForDevice)
                
                // ✅ NEW: Toggle for Table of Contents
                Toggle("Include Table of Contents", isOn: $conversionManager.conversionSettings.epubSettings.includeTableOfContents)
                
                if conversionManager.conversionSettings.optimizeForDevice {
                    Picker("Target Device", selection: $conversionManager.conversionSettings.targetDevice) {
                        ForEach(KindleDeviceType.allCases, id: \.self) { device in
                            HStack {
                                Image(systemName: device.icon)
                                Text(device.rawValue)
                            }
                            .tag(device)
                        }
                    }
                }
            }
            
            Section(header: Text("Image Enhancements")) {
                Toggle("Grayscale (E-Ink Mode)", isOn: $conversionManager.conversionSettings.imageEnhancement.grayscale)
                Toggle("Auto Contrast", isOn: $conversionManager.conversionSettings.imageEnhancement.autoContrast)
                Toggle("Invert Colors (Dark Mode)", isOn: $conversionManager.conversionSettings.imageEnhancement.invertColors)
                
                if conversionManager.conversionSettings.imageEnhancement.grayscale == false {
                    HStack {
                        Text("Brightness")
                        Slider(value: $conversionManager.conversionSettings.imageEnhancement.brightness, in: -0.5...0.5)
                    }
                    HStack {
                        Text("Sharpness")
                        Slider(value: $conversionManager.conversionSettings.imageEnhancement.sharpness, in: 0.0...1.0)
                    }
                }
            }
            
            Section(header: Text("Defaults (Applied at Start)")) {
                Toggle("Default to Manga Mode", isOn: $conversionManager.conversionSettings.mangaMode)
                Toggle("Default Panel Detection", isOn: $conversionManager.conversionSettings.enablePanelSplit)
                
                if conversionManager.conversionSettings.enablePanelSplit {
                    Toggle("Guided View (Show Full Page First)", isOn: $conversionManager.conversionSettings.epubSettings.includeFullPage)
                        .foregroundColor(.blue)

                    // ✅ NEW: Export Format Toggle
                    Picker("Guided View Format", selection: $conversionManager.conversionSettings.epubSettings.guidedViewExportFormat) {
                        ForEach(EPUBSettings.GuidedViewExportFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 4)
                    
                    Picker("Detection Mode", selection: $conversionManager.conversionSettings.epubSettings.panelDetectionMode) {
                        Text("Automatic (Standard)").tag(PanelExtractor.ExtractionMode.automatic)
                        Text("Aggressive (Find More)").tag(PanelExtractor.ExtractionMode.aggressive)
                        Text("Conservative (Strict)").tag(PanelExtractor.ExtractionMode.conservative)
                        Text("Grid (2x2)").tag(PanelExtractor.ExtractionMode.grid)
                    }
                }
            }
            
            Section {
                Button("Save as Default Preset") {
                    let newPreset = ConversionPreset(name: "Custom Settings", settings: conversionManager.conversionSettings)
                    conversionManager.savePreset(newPreset)
                }
            }

            

        }
        .navigationTitle("Settings")
        .onChange(of: conversionManager.conversionSettings) { _ in
            conversionManager.saveSettings()
        }
    }
}

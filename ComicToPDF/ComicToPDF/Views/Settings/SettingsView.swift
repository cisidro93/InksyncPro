import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    // ✅ NEW: Observe the Brain
    @StateObject private var aiManager = AdaptiveLearningManager.shared
    
    @State private var showingAddDevice = false
    @State private var showingDeleteAlert = false
    @State private var deviceToDelete: KindleDevice?
    
    // ✅ NEW: API Key Verification State
    @State private var isVerifying = false
    @State private var verificationStatus: KeyStatus = .none
    
    enum KeyStatus {
        case none, verifying, success, invalid, localizedError(String)
        
        var title: String {
            switch self {
            case .none: return "Verify Key"
            case .verifying: return "Verifying..."
            case .success: return "Key Validated"
            case .invalid: return "Invalid Key"
            case .localizedError(let msg): return msg
            }
        }
        
        var icon: String? {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .invalid, .localizedError: return "exclamationmark.triangle.fill"
            default: return nil
            }
        }
        
        var color: Color {
            switch self {
            case .success: return .green
            case .invalid, .localizedError: return .red
            default: return .primary
            }
        }
    }
    
    func verifyAPIKey() {
        let key = conversionManager.conversionSettings.comicVineAPIKey
        guard !key.isEmpty else { return }
        
        isVerifying = true
        verificationStatus = .verifying
        
        Task {
            let isValid = await ComicVineService.shared.validateAPIKey(key)
            await MainActor.run {
                isVerifying = false
                verificationStatus = isValid ? .success : .invalid
            }
        }
    }
    
    var body: some View {
        Form {


            // ✅ NEW: Appearance Section
            Section(header: Text("Appearance")) {
                Picker("Text Size", selection: $conversionManager.conversionSettings.textSize) {
                    ForEach(AppTextSize.allCases) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                
                HStack {
                    Image(systemName: "textformat.size")
                    Text("Adjusts the app's font scaling.")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                
                // ✅ NEW: Panel Strategy Picker REMOVED (User Request)
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
            } // Close Section
            
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
                    HStack {
                        Text("Gamma (E-Ink)")
                        Slider(value: $conversionManager.conversionSettings.imageEnhancement.gamma, in: 0.5...2.5)
                        Text(String(format: "%.1f", conversionManager.conversionSettings.imageEnhancement.gamma))
                            .font(.caption).monospacedDigit()
                    }
                }
            }
            
            Section(header: Text("Defaults (Applied at Start)")) {
                Toggle("Default to Manga Mode", isOn: $conversionManager.conversionSettings.mangaMode)
                Toggle("Default Panel Detection", isOn: $conversionManager.conversionSettings.enablePanelSplit)
                
                if conversionManager.conversionSettings.enablePanelSplit {
                    Toggle("Guided View (Show Full Page First)", isOn: $conversionManager.conversionSettings.epubSettings.includeFullPage)
                        .foregroundColor(.blue)

                    // ✅ NEW: Export Format Toggle REMOVED - Enforcing EPUB
                    
                    // ✅ NEW: Editor Presentation Mode
                    Picker("Editor Presentation", selection: $conversionManager.conversionSettings.panelEditorMode) {
                        ForEach(PanelEditorPresentationMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Picker("Detection Mode", selection: $conversionManager.conversionSettings.epubSettings.panelDetectionMode) {
                        Text("Automatic (Standard)").tag(PanelExtractor.ExtractionMode.automatic)
                        Text("Aggressive (Find More)").tag(PanelExtractor.ExtractionMode.aggressive)
                        Text("Conservative (Strict)").tag(PanelExtractor.ExtractionMode.conservative)
                        Text("Grid (2x2)").tag(PanelExtractor.ExtractionMode.grid)
                    }
                }
            }
            
            Section(header: Text("Text Recognition (OCR)")) {
                Picker("Language", selection: $conversionManager.conversionSettings.ocrLanguage) {
                    ForEach(OCRLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
            }
            
            Section(header: Text("Integrations")) {
                SecureField("ComicVine API Key", text: $conversionManager.conversionSettings.comicVineAPIKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                
                if !conversionManager.conversionSettings.comicVineAPIKey.isEmpty {
                    Button(action: verifyAPIKey) {
                        HStack {
                            Text(verificationStatus.title)
                            if isVerifying {
                                ProgressView().padding(.leading, 5)
                            } else if let icon = verificationStatus.icon {
                                Image(systemName: icon)
                                    .foregroundColor(verificationStatus.color)
                            }
                        }
                    }
                    .disabled(isVerifying)
                }
                
                Link("Get Free API Key", destination: URL(string: "https://comicvine.gamespot.com/api/")!)
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            
            // ✅ NEW: AI Learning Visualization
            Section(header: Text("AI Learning Status")) {
                let params = AdaptiveLearningManager.shared.currentSettings
                HStack {
                    Text("Minimum Confidence")
                    Spacer()
                    Text(String(format: "%.0f%%", params.minConfidence * 100))
                        .foregroundColor(.blue)
                }
                HStack {
                    Text("Scan Sensitivity (Min Size)")
                    Spacer()
                    Text(String(format: "%.1f%%", params.minSize * 100))
                        .foregroundColor(.blue)
                }
                
                Button("Reset Learning Memory") {
                    AdaptiveLearningManager.shared.resetToDefaults()
                }
                .foregroundColor(.red)
            }
            
            Section {
                Button("Save as Default Preset") {
                    let newPreset = ConversionPreset(name: "Custom Settings", settings: conversionManager.conversionSettings)
                    conversionManager.savePreset(newPreset)
                }
            }
            
            Section(header: Text("Debugging")) {
                Toggle("Show Editor Debugger", isOn: $conversionManager.conversionSettings.showEditorDebug)
                
                NavigationLink(destination: LogsView()) {
                    Label("View Debug Logs", systemImage: "ladybug")
                }
            }
            
            // ✅ NEW: Help & Support Section
            Section(header: Text("Help & Support")) {
                NavigationLink(destination: HelpCenterView()) {
                    Label("Help Center", systemImage: "questionmark.circle.fill")
                }
            }

        }
        .navigationTitle("Settings")
        .onChange(of: conversionManager.conversionSettings) { _ in
            conversionManager.saveSettings()
        }
    }
}

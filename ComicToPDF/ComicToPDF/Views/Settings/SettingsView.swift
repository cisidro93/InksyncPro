import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    // ✅ Observe Global Layout Setting
    @AppStorage("useSidebar") private var useSidebar = true
    
    // ✅ NEW: Kindle Email Storage
    @AppStorage("kindleEmail") private var kindleEmail: String = ""
    
    // ✅ NEW: Observe the Brain
    @StateObject private var aiManager = AdaptiveLearningManager.shared
    
    @State private var showingAddDevice = false
    @State private var showingDeleteAlert = false
    @State private var deviceToDelete: KindleDevice?
    
    // ✅ NEW: Preset Alert State
    @State private var showingPresetAlert = false
    @State private var customPresetName = "Custom Base"
    @Environment(\.dismiss) var dismiss
    
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
    
    // Helper to generate App-Store quality iOS Settings icons
    private func settingsIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(color)
            .cornerRadius(6)
    }

    var body: some View {
        Form {
            generalUISection
            sendToKindleSection
            exportDefaultsSection
            processingEngineSection
            
            imageFiltersSection
                HStack {
                    settingsIcon("swatchpalette.fill", color: .teal)
                    Toggle("Convert to Grayscale", isOn: $conversionManager.conversionSettings.imageEnhancement.grayscale)
                }
                HStack {
                    settingsIcon("circle.lefthalf.filled", color: .teal)
                    Toggle("Auto-Levels (Histogram Stretch)", isOn: $conversionManager.conversionSettings.imageEnhancement.autoContrast)
                }
                HStack {
                    settingsIcon("moon.stars.fill", color: .teal)
                    Toggle("Invert Colors (Dark Mode)", isOn: $conversionManager.conversionSettings.imageEnhancement.invertColors)
                }
                
                if !conversionManager.conversionSettings.imageEnhancement.grayscale {
                    VStack(alignment: .leading) {
                        Text("Brightness").font(.caption)
                        Slider(value: $conversionManager.conversionSettings.imageEnhancement.brightness, in: -0.5...0.5)
                    }
                    VStack(alignment: .leading) {
                        HStack { Text("Sharpness (E-Ink Clarity)").font(.caption); Spacer(); Text(String(format: "%.1f", conversionManager.conversionSettings.imageEnhancement.sharpness)).font(.caption).monospacedDigit() }
                        Slider(value: $conversionManager.conversionSettings.imageEnhancement.sharpness, in: 0.0...1.0)
                    }
                    VStack(alignment: .leading) {
                        HStack { Text("Color Vibrance (Colorsoft/Kaleido)").font(.caption); Spacer(); Text(String(format: "%.2f", conversionManager.conversionSettings.imageEnhancement.vibrance)).font(.caption).monospacedDigit() }
                        Slider(value: $conversionManager.conversionSettings.imageEnhancement.vibrance, in: 0.0...1.0)
                    }
                    VStack(alignment: .leading) {
                        HStack { Text("Gamma").font(.caption); Spacer(); Text(String(format: "%.1f", conversionManager.conversionSettings.imageEnhancement.gamma)).font(.caption).monospacedDigit() }
                        Slider(value: $conversionManager.conversionSettings.imageEnhancement.gamma, in: 0.5...2.5)
                    }
            aiSection
            integrationsSection
            systemSection
            legalSection
        }
        .navigationTitle("Preferences")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { dismiss() }) { Text("Done").bold() }
            }
        }
        .onChange(of: conversionManager.conversionSettings) { _ in
            conversionManager.saveSettings()
        }
        .alert("Save Custom Preset", isPresented: $showingPresetAlert) {
            TextField("Preset Name", text: $customPresetName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                let newPreset = ConversionPreset(name: customPresetName.isEmpty ? "Custom Mode" : customPresetName, settings: conversionManager.conversionSettings)
                conversionManager.savePreset(newPreset)
            }
        } message: { Text("Enter a name for your custom export configuration.") }
    }
    
    // MARK: - Extracted Sections
    
    @ViewBuilder
    private var generalUISection: some View {
        Section {
            HStack {
                settingsIcon("textformat.size", color: .blue)
                Picker("App Text Size", selection: $conversionManager.conversionSettings.textSize) {
                    ForEach(AppTextSize.allCases) { size in Text(size.rawValue).tag(size) }
                }
                .pickerStyle(.menu)
            }
            
            HStack {
                settingsIcon("uiwindow.split.2x1", color: .blue)
                Picker("Editor Interface", selection: $conversionManager.conversionSettings.panelEditorMode) {
                    ForEach(PanelEditorPresentationMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.menu)
            }
            
            HStack {
                settingsIcon("book.fill", color: .purple)
                Toggle("Default Manga Mode (RTL)", isOn: $conversionManager.conversionSettings.mangaMode)
            }
            
            HStack {
                settingsIcon("sidebar.left", color: .indigo)
                Toggle("Use Sidebar Navigation (iPad)", isOn: $useSidebar)
            }

            VStack(alignment: .leading) {
                Toggle("Async Background Conversions", isOn: $conversionManager.conversionSettings.enableBackgroundQueue)
                Text("When enabled, exporting files will enter a background queue instead of blocking the screen, allowing you to continue using the app.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: { Text("General UI") }
    }
    
    @ViewBuilder
    private var sendToKindleSection: some View {
        Section(header: Text("Send to Kindle").font(.footnote).foregroundColor(.secondary)) {
            HStack {
                settingsIcon("envelope.fill", color: .black)
                TextField("Your @kindle.com Email", text: $kindleEmail)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
        }
    }
    
    @ViewBuilder
    private var exportDefaultsSection: some View {
        Section {
            HStack {
                settingsIcon("doc.zipper", color: .orange)
                Picker("Default Output Format", selection: $conversionManager.conversionSettings.outputFormat) {
                    ForEach(OutputFormat.allCases) { format in Label(format.rawValue, systemImage: format.icon).tag(format) }
                }
                .pickerStyle(.menu)
                .onChange(of: conversionManager.conversionSettings.outputFormat) { newFormat in
                    if newFormat != .epub { conversionManager.conversionSettings.outputPipeline = .standard }
                }
            }
            
            // Custom Export Profiles
            NavigationLink(destination: ExportProfilesView()) {
                HStack {
                    settingsIcon("list.clipboard.fill", color: .orange)
                    Text("Custom Export Profiles")
                }
            }
            
            if conversionManager.conversionSettings.outputFormat == .epub {
                HStack {
                    settingsIcon("rectangle.grid.1x2.fill", color: .indigo)
                    Picker("EPUB Conversion Mode", selection: $conversionManager.conversionSettings.outputPipeline) {
                        ForEach(OutputPipeline.allCases) { pipeline in Text(pipeline.rawValue).tag(pipeline) }
                    }
                    .pickerStyle(.menu)
                }
                
                if conversionManager.conversionSettings.outputPipeline == .proPanel {
                    HStack {
                        settingsIcon("eye.fill", color: .indigo)
                        Toggle("Guided View: Show Full Page First", isOn: $conversionManager.conversionSettings.epubSettings.includeFullPage)
                    }
                }
            }
            
            HStack {
                settingsIcon("scissors", color: .orange)
                Picker("Auto Split Oversized Files", selection: $conversionManager.conversionSettings.splitMode) {
                    ForEach(FileSizeSplitMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.menu)
            }
            
            HStack {
                settingsIcon("kindle", color: .black)
                Toggle("Optimize for E-Readers", isOn: $conversionManager.conversionSettings.optimizeForDevice)
            }
            
            if conversionManager.conversionSettings.optimizeForDevice {
                HStack {
                    settingsIcon("display", color: .gray)
                    Picker("Target Device", selection: $conversionManager.conversionSettings.targetDevice) {
                        ForEach(KindleDeviceType.allCases, id: \.self) { device in
                            HStack { Image(systemName: device.icon); Text(device.rawValue) }.tag(device)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            
            HStack {
                settingsIcon("list.bullet.rectangle.portrait", color: .gray)
                Toggle("Build Table of Contents", isOn: $conversionManager.conversionSettings.epubSettings.includeTableOfContents)
            }
            
        } header: { Text("Export & Conversion") }
    }
    
    @ViewBuilder
    private var processingEngineSection: some View {
        Section {
            HStack {
                settingsIcon("photo.stack.fill", color: .green)
                Picker("Image Compression", selection: $conversionManager.conversionSettings.compressionQuality) {
                    ForEach(CompressionPreset.allCases, id: \.self) { preset in Text(preset.rawValue).tag(preset) }
                }
                .pickerStyle(.menu)
            }
            
            HStack {
                settingsIcon("crop", color: .green)
                Toggle("Smart Border Trimming", isOn: $conversionManager.conversionSettings.trimMargins)
            }
            
            HStack {
                settingsIcon("character.book.closed.fill", color: .green)
                Picker("OCR Language Engine", selection: $conversionManager.conversionSettings.ocrLanguage) {
                    ForEach(OCRLanguage.allCases) { lang in Text(lang.displayName).tag(lang) }
                }
                .pickerStyle(.menu)
            }
        } header: { Text("Processing Engine") }
    }
    
    @ViewBuilder
    private var imageFiltersSection: some View {
        Section {
            HStack {
                settingsIcon("swatchpalette.fill", color: .teal)
                Toggle("Convert to Grayscale", isOn: $conversionManager.conversionSettings.imageEnhancement.grayscale)
            }
            HStack {
                settingsIcon("circle.lefthalf.filled", color: .teal)
                Toggle("Auto-Levels (Histogram Stretch)", isOn: $conversionManager.conversionSettings.imageEnhancement.autoContrast)
            }
            HStack {
                settingsIcon("moon.stars.fill", color: .teal)
                Toggle("Invert Colors (Dark Mode)", isOn: $conversionManager.conversionSettings.imageEnhancement.invertColors)
            }
            
            if !conversionManager.conversionSettings.imageEnhancement.grayscale {
                VStack(alignment: .leading) {
                    Text("Brightness").font(.caption)
                    Slider(value: $conversionManager.conversionSettings.imageEnhancement.brightness, in: -0.5...0.5)
                }
                VStack(alignment: .leading) {
                    HStack { Text("Sharpness (E-Ink Clarity)").font(.caption); Spacer(); Text(String(format: "%.1f", conversionManager.conversionSettings.imageEnhancement.sharpness)).font(.caption).monospacedDigit() }
                    Slider(value: $conversionManager.conversionSettings.imageEnhancement.sharpness, in: 0.0...1.0)
                }
                VStack(alignment: .leading) {
                    HStack { Text("Color Vibrance (Colorsoft/Kaleido)").font(.caption); Spacer(); Text(String(format: "%.2f", conversionManager.conversionSettings.imageEnhancement.vibrance)).font(.caption).monospacedDigit() }
                    Slider(value: $conversionManager.conversionSettings.imageEnhancement.vibrance, in: 0.0...1.0)
                }
                VStack(alignment: .leading) {
                    HStack { Text("Gamma").font(.caption); Spacer(); Text(String(format: "%.1f", conversionManager.conversionSettings.imageEnhancement.gamma)).font(.caption).monospacedDigit() }
                    Slider(value: $conversionManager.conversionSettings.imageEnhancement.gamma, in: 0.5...2.5)
                }
            }
        } header: { Text("Image Filters") }
    }
    
    @ViewBuilder
    private var aiSection: some View {
        Section {
            if conversionManager.conversionSettings.outputFormat == .epub && conversionManager.conversionSettings.outputPipeline == .proPanel {
                HStack {
                    settingsIcon("viewfinder", color: .cyan)
                    Picker("Vision Node Sensitivity", selection: $conversionManager.conversionSettings.epubSettings.panelDetectionMode) {
                        Text("Standard Flow").tag(PanelExtractor.ExtractionMode.automatic)
                        Text("Aggressive (Deep Scan)").tag(PanelExtractor.ExtractionMode.aggressive)
                        Text("Conservative").tag(PanelExtractor.ExtractionMode.conservative)
                        Text("Fixed Grid (2x2)").tag(PanelExtractor.ExtractionMode.grid)
                    }
                    .pickerStyle(.menu)
                }
            }
            
            let params = AdaptiveLearningManager.shared.currentSettings
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    settingsIcon("network.badge.shield.half.filled", color: .cyan)
                    Text("AI Confidence Threshold")
                    Spacer()
                    Text("\(Int(params.minConfidence * 100))%")
                }
                HStack {
                    settingsIcon("perspective", color: .cyan)
                    Text("AI Size Relevancy")
                    Spacer()
                    Text("\(String(format: "%.1f", params.minSize * 100))%")
                }
            }
            .font(.subheadline)
            
            Button(action: { AdaptiveLearningManager.shared.resetToDefaults() }) {
                Text("Reset Neural Tracking History").foregroundColor(.red).font(.subheadline)
            }
            
        } header: { Text("AI Intelligence") } footer: {
            Text("Inksync Pro learns from the changes you make in the Panel Editor, dynamically tuning its vision nodes over time to match your aesthetic preferences.")
        }
    }
    
    @ViewBuilder
    private var integrationsSection: some View {
        Section {
            HStack {
                settingsIcon("server.rack", color: .indigo)
                SecureField("ComicVine API Key", text: $conversionManager.conversionSettings.comicVineAPIKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            
            if !conversionManager.conversionSettings.comicVineAPIKey.isEmpty {
                Button(action: verifyAPIKey) {
                    HStack {
                        Text(verificationStatus.title)
                        Spacer()
                        if isVerifying { ProgressView() } 
                        else if let icon = verificationStatus.icon { Image(systemName: icon).foregroundColor(verificationStatus.color) }
                    }
                }
                .disabled(isVerifying)
            }
            
            Link("Get Free API Key", destination: URL(string: "https://comicvine.gamespot.com/api/")!)
                .font(.caption).foregroundColor(.blue)
        } header: { Text("Integrations") }
    }
    
    @ViewBuilder
    private var systemSection: some View {
        Section {
            Button(action: {
                showingPresetAlert = true
            }) {
                HStack {
                    settingsIcon("square.and.arrow.down.fill", color: .blue)
                    Text("Save Settings as Preset").foregroundColor(.primary)
                }
            }
            
            Toggle(isOn: $conversionManager.conversionSettings.showEditorDebug) {
                HStack {
                    settingsIcon("ladybug.fill", color: .red)
                    Text("Enable Developer Tools")
                }
            }
            
            NavigationLink(destination: LogsView()) {
                HStack {
                    settingsIcon("terminal.fill", color: .gray)
                    Text("View Diagnostic Logs")
                }
            }
            
            NavigationLink(destination: HelpCenterView()) {
                HStack {
                    settingsIcon("questionmark.circle.fill", color: .blue)
                    Text("Help & Documentation")
                }
            }
        } header: { Text("System") }
    }
    
    @ViewBuilder
    private var legalSection: some View {
        Section {
            Link(destination: URL(string: "https://inksyncpro.app/privacy.html")!) {
                HStack {
                    settingsIcon("hand.raised.fill", color: .blue)
                    Text("Privacy Policy")
                }
            }
        } header: { Text("Legal") }
    }
}

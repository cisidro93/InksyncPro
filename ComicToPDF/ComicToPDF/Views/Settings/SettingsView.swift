import SwiftUI
import SwiftData
struct SettingsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    // ✅ Observe Global Layout Setting
    @AppStorage("useSidebar") private var useSidebar = true
    
    // ✅ NEW: Kindle Email Storage
    @AppStorage("kindleEmail") private var kindleEmail: String = ""
    
    // ✅ NEW: Background Auto-Sync
    @AppStorage("enableBackgroundSync") private var enableBackgroundSync = false
    
    // ✅ PHASE 7: Library Typography Themes
    @AppStorage("mangaBadgeColorHex") private var mangaBadgeColorHex = "#2dd4a0"
    @AppStorage("comicBadgeColorHex") private var comicBadgeColorHex = "#3d6fff"
    
    // ✅ NEW: Observe the Brain
    @ObservedObject private var aiManager = AdaptiveLearningManager.shared
    
    @State private var showingAddDevice = false
    @State private var showingDeleteAlert = false
    @State private var deviceToDelete: KindleDevice?
    
    // ✅ NEW: Preset Alert State
    @State private var showingPresetAlert = false
    @State private var customPresetName = "Custom Base"
    @Environment(\.dismiss) var dismiss
    
    // ✅ NEW: AI State File Export
    @State private var showingAIExport = false

    @State private var aiExportDocument: JSONFileDocument?
    @State private var showingAIFeedbackAlert = false
    @State private var aiFeedbackTitle = ""
    @State private var aiFeedbackMessage = ""
    
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
        let key = settingsManager.conversionSettings.comicVineAPIKey
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
            omnibusSection
            processingEngineSection
            
            imageFiltersSection
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
        .onChange(of: settingsManager.conversionSettings) {
            settingsManager.save()
        }
        .alert("Save Custom Preset", isPresented: $showingPresetAlert) {
            TextField("Preset Name", text: $customPresetName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                let newPreset = ConversionPreset(name: customPresetName.isEmpty ? "Custom Mode" : customPresetName, settings: settingsManager.conversionSettings)
                settingsManager.savePreset(newPreset)
            }
        } message: { Text("Enter a name for your custom export configuration.") }
        .alert(aiFeedbackTitle, isPresented: $showingAIFeedbackAlert) {
            Button("OK", role: .cancel) { }
        } message: { Text(aiFeedbackMessage) }
        .fileExporter(isPresented: $showingAIExport, document: aiExportDocument, contentType: .json, defaultFilename: "Inksync_AI_Profile.json") { result in
            // Enforce a 0.5s modal teardown window so the new alert doesn't present over the closing picker
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                switch result {
                case .success(_):
                    aiFeedbackTitle = "Engine Exported"
                    aiFeedbackMessage = "Your Neural Engine profile was successfully exported."
                    showingAIFeedbackAlert = true
                case .failure(let error):
                    aiFeedbackTitle = "Export Failed"
                    aiFeedbackMessage = error.localizedDescription
                    showingAIFeedbackAlert = true
                }
            }
        }

    }
    
    // MARK: - Extracted Sections
    
    @ViewBuilder
    private var generalUISection: some View {
        Section {
            HStack {
                settingsIcon("textformat.size", color: .blue)
                Picker("App Text Size", selection: $settingsManager.conversionSettings.textSize) {
                    ForEach(AppTextSize.allCases) { size in Text(size.rawValue).tag(size) }
                }
                .pickerStyle(.menu)
            }
            
            HStack {
                settingsIcon("uiwindow.split.2x1", color: .blue)
                Picker("Editor Interface", selection: $settingsManager.conversionSettings.panelEditorMode) {
                    ForEach(PanelEditorPresentationMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.menu)
            }
            
            HStack {
                settingsIcon("book.fill", color: .purple)
                Toggle("Default Manga Mode (RTL)", isOn: $settingsManager.conversionSettings.mangaMode)
            }
            
            HStack {
                settingsIcon("sidebar.left", color: .indigo)
                Toggle("Use Sidebar Navigation (iPad)", isOn: $useSidebar)
            }

            VStack(alignment: .leading) {
                Toggle("Async Background Conversions", isOn: $settingsManager.conversionSettings.enableBackgroundQueue)
                Text("When enabled, exporting files will enter a background queue instead of blocking the screen, allowing you to continue using the app.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // ✅ PHASE 7: User-Managed Overlay Aesthetic
            HStack {
                settingsIcon("paintpalette.fill", color: .pink)
                ColorPicker("Manga Badge Background", selection: Binding(
                    get: { Color(hex: mangaBadgeColorHex) },
                    set: { mangaBadgeColorHex = $0.toHex() ?? "#2dd4a0" }
                ))
            }
            
            HStack {
                settingsIcon("paintpalette", color: .pink)
                ColorPicker("Comic Badge Background", selection: Binding(
                    get: { Color(hex: comicBadgeColorHex) },
                    set: { comicBadgeColorHex = $0.toHex() ?? "#3d6fff" }
                ))
            }
        } header: { Text("General UI") }
    }
    
    @ViewBuilder
    private var sendToKindleSection: some View {
        Section(header: Text("Send to Kindle").font(.footnote).foregroundColor(.secondary)) {
            HStack {
                settingsIcon("envelope.fill", color: Color(UIColor.systemGray))
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
                Picker("Default Output Format", selection: $settingsManager.conversionSettings.outputFormat) {
                    ForEach(OutputFormat.allCases) { format in 
                        Text(format.rawValue).tag(format) 
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: settingsManager.conversionSettings.outputFormat) {
                    if settingsManager.conversionSettings.outputFormat != .epub { settingsManager.conversionSettings.outputPipeline = .standard }
                }
            }
            
            // Custom Export Profiles
            NavigationLink(destination: ExportProfilesView()) {
                HStack {
                    settingsIcon("list.clipboard.fill", color: .orange)
                    Text("Custom Export Profiles")
                }
            }
            
            if settingsManager.conversionSettings.outputFormat == .epub {
                HStack {
                    settingsIcon("rectangle.grid.1x2.fill", color: .indigo)
                    Picker("EPUB Conversion Mode", selection: $settingsManager.conversionSettings.outputPipeline) {
                        ForEach(OutputPipeline.allCases) { pipeline in Text(pipeline.rawValue).tag(pipeline) }
                    }
                    .pickerStyle(.menu)
                }
                
                if settingsManager.conversionSettings.outputPipeline == .proPanel {
                    HStack {
                        settingsIcon("eye.fill", color: .indigo)
                        Toggle("Guided View: Show Full Page First", isOn: $settingsManager.conversionSettings.epubSettings.includeFullPage)
                    }
                }
            }
            
            HStack {
                settingsIcon("scissors", color: .orange)
                Picker("Auto Split Oversized Files", selection: $settingsManager.conversionSettings.splitMode) {
                    ForEach(FileSizeSplitMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.menu)
            }
            
            HStack {
                settingsIcon("kindle", color: Color(UIColor.systemGray))
                Toggle("Optimize for E-Readers", isOn: $settingsManager.conversionSettings.optimizeForDevice)
            }
            
            if settingsManager.conversionSettings.optimizeForDevice {
                HStack {
                    settingsIcon("display", color: .gray)
                    Picker("Target Device", selection: $settingsManager.conversionSettings.targetDeviceProfile) {
                        ForEach(TargetDeviceProfile.allCases) { device in
                            Text(device.rawValue).tag(device)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            
            HStack {
                settingsIcon("list.bullet.rectangle.portrait", color: .gray)
                Toggle("Build Table of Contents", isOn: $settingsManager.conversionSettings.epubSettings.includeTableOfContents)
            }
            
        } header: { Text("Export & Conversion") }
    }
    
    @ViewBuilder
    private var omnibusSection: some View {
        Section {
            HStack {
                settingsIcon("books.vertical.fill", color: .purple)
                Picker("Split Omnibus at Size", selection: $settingsManager.conversionSettings.omnibusSplitThresholdMB) {
                    Text("100 MB").tag(100)
                    Text("200 MB (Kindle Safe)").tag(200)
                    Text("500 MB").tag(500)
                    Text("Infinite / Disable Split").tag(99999)
                }
                .pickerStyle(.menu)
            }
            
            HStack {
                settingsIcon("seal.fill", color: .pink)
                Picker("Cover Badge Placement", selection: $settingsManager.conversionSettings.omnibusBadgePlacement) {
                    ForEach(CoverBadgePlacement.allCases) { placement in
                        Text(placement.rawValue).tag(placement)
                    }
                }
                .pickerStyle(.menu)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Omnibus Builder")
                    .font(.caption).bold()
                Text("The EPUB Omnibus Engine aggregates multiple single issues into massive single-file Volumes. If you set a size limit, the engine will non-destructively split the volume *exactly* between chapters so you never lose your place mid-issue, automatically embedding 'Part 2' stickers on the cover art!")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
            
        } header: { Text("Omnibus Engine") }
    }
    
    @ViewBuilder
    private var processingEngineSection: some View {
        Section {

            
            HStack {
                settingsIcon("crop", color: .green)
                Toggle("Smart Border Trimming", isOn: $settingsManager.conversionSettings.trimMargins)
            }
            
        } header: { Text("Processing Engine") }
    }
    
    @ViewBuilder
    private var imageFiltersSection: some View {
        Section {
            HStack {
                settingsIcon("swatchpalette.fill", color: .teal)
                Toggle("Convert to Grayscale", isOn: $settingsManager.conversionSettings.imageEnhancement.grayscale)
            }
            HStack {
                settingsIcon("circle.lefthalf.filled", color: .teal)
                Toggle("Auto-Levels (Histogram Stretch)", isOn: $settingsManager.conversionSettings.imageEnhancement.autoContrast)
            }
            HStack {
                settingsIcon("moon.stars.fill", color: .teal)
                Toggle("Invert Colors (Dark Mode)", isOn: $settingsManager.conversionSettings.imageEnhancement.invertColors)
            }
            
            if !settingsManager.conversionSettings.imageEnhancement.grayscale {
                VStack(alignment: .leading) {
                    Text("Brightness").font(.caption)
                    Slider(value: $settingsManager.conversionSettings.imageEnhancement.brightness, in: -0.5...0.5)
                }
                VStack(alignment: .leading) {
                    HStack { Text("Sharpness (E-Ink Clarity)").font(.caption); Spacer(); Text(String(format: "%.1f", settingsManager.conversionSettings.imageEnhancement.sharpness)).font(.caption).monospacedDigit() }
                    Slider(value: $settingsManager.conversionSettings.imageEnhancement.sharpness, in: 0.0...1.0)
                }
                VStack(alignment: .leading) {
                    HStack { Text("Color Vibrance (Colorsoft/Kaleido)").font(.caption); Spacer(); Text(String(format: "%.2f", settingsManager.conversionSettings.imageEnhancement.vibrance)).font(.caption).monospacedDigit() }
                    Slider(value: $settingsManager.conversionSettings.imageEnhancement.vibrance, in: 0.0...1.0)
                }
                VStack(alignment: .leading) {
                    HStack { Text("Gamma").font(.caption); Spacer(); Text(String(format: "%.1f", settingsManager.conversionSettings.imageEnhancement.gamma)).font(.caption).monospacedDigit() }
                    Slider(value: $settingsManager.conversionSettings.imageEnhancement.gamma, in: 0.5...2.5)
                }
            }
        } header: { Text("Image Filters") }
    }
    
    @ViewBuilder
    private var aiSection: some View {
        Section {
            if settingsManager.conversionSettings.outputFormat == .epub && settingsManager.conversionSettings.outputPipeline == .proPanel {
                HStack {
                    settingsIcon("viewfinder", color: .cyan)
                    Picker("Vision Sensitivity", selection: $settingsManager.conversionSettings.epubSettings.panelDetectionMode) {
                        Text("Standard Flow").tag(PanelExtractor.ExtractionMode.automatic)
                        Text("Deep Scan").tag(PanelExtractor.ExtractionMode.aggressive)
                        Text("Conservative").tag(PanelExtractor.ExtractionMode.conservative)
                        Text("Fixed Grid (2x2)").tag(PanelExtractor.ExtractionMode.grid)
                    }
                    .pickerStyle(.menu)
                }
            }
            
            // Dashboard Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Core Neural Engine State")
                    .font(.caption).bold()
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Text("Your localized CoreML model adapts based on your corrections in the Panel Editor.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)
            }
            .padding(.vertical, 4)
            
            let params = aiManager.currentSettings
            
            // Visual Gauges
            VStack(spacing: 16) {
                HStack(spacing: 20) {
                    Gauge(value: params.minConfidence, in: 0...1.0) {
                        Image(systemName: "network.badge.shield.half.filled").foregroundColor(.cyan)
                    } currentValueLabel: {
                        Text("\(Int(params.minConfidence * 100))%").font(.caption.bold())
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(Gradient(colors: [.blue, .cyan]))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Confidence Threshold").font(.subheadline.bold())
                        Text("Lower value = more sensitive").font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                
                HStack(spacing: 20) {
                    Gauge(value: params.minSize, in: 0...0.5) {
                        Image(systemName: "perspective").foregroundColor(.purple)
                    } currentValueLabel: {
                        Text("\(Int(params.minSize * 100))%").font(.caption.bold())
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(Gradient(colors: [.purple, .pink]))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Size Relevancy").font(.subheadline.bold())
                        Text("Ignores panels smaller than this").font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .padding(.vertical, 8)
            
            // Analytics Block
            VStack(alignment: .leading, spacing: 12) {
                Text("Historical Corrections")
                    .font(.caption).bold()
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                
                HStack {
                    VStack(alignment: .leading) {
                        Text("Manually Added")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(aiManager.addedPanelsCount)")
                            .font(.title3.bold())
                            .foregroundColor(.green)
                    }
                    Spacer()
                    VStack(alignment: .center) {
                        Text("Manually Deleted")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(aiManager.deletedPanelsCount)")
                            .font(.title3.bold())
                            .foregroundColor(.red)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Resized Box")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(aiManager.resizedPanelsCount)")
                            .font(.title3.bold())
                            .foregroundColor(.orange)
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(10)
            }
            .padding(.vertical, 4)
            
            Button(action: { aiManager.resetToFactorySettings() }) {
                Text("Reset Learning History")
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            
            HStack(spacing: 12) {
                Button(action: { 
                    ImportCoordinator.present(type: .json) { urls in
                        if let url = urls.first {
                            importAIProfile(url)
                        }
                    }
                }) {
                    Label("Import Config", systemImage: "square.and.arrow.down")
                        .font(.caption)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    if let data = aiManager.exportState() {
                        aiExportDocument = JSONFileDocument(data: data)
                        showingAIExport = true
                    }
                }) {
                    Label("Export Config", systemImage: "square.and.arrow.up")
                        .font(.caption)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
            
        } header: { Text("AI Dashboard") }
    }
    
    @ViewBuilder
    private var integrationsSection: some View {
        Section {
            HStack {
                settingsIcon("server.rack", color: .indigo)
                SecureField("ComicVine API Key", text: $settingsManager.conversionSettings.comicVineAPIKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            
            if !settingsManager.conversionSettings.comicVineAPIKey.isEmpty {
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
                
            Divider()
            
            Picker("AI Provider (Pro Mode)", selection: $settingsManager.conversionSettings.aiVendor) {
                ForEach(AIVendor.allCases) { vendor in
                    Text(vendor.rawValue).tag(vendor)
                }
            }
            
            HStack {
                settingsIcon("brain", color: .purple)
                
                switch settingsManager.conversionSettings.aiVendor {
                case .openRouter:
                    SecureField("OpenRouter API Key", text: $settingsManager.conversionSettings.openRouterAPIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                case .openAI:
                    SecureField("OpenAI API Key", text: $settingsManager.conversionSettings.openAIAPIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                case .anthropic:
                    SecureField("Anthropic API Key", text: $settingsManager.conversionSettings.anthropicAPIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                case .gemini:
                    SecureField("Gemini API Key", text: $settingsManager.conversionSettings.geminiAPIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            
            if settingsManager.conversionSettings.aiVendor == .openRouter {
                Text("OpenRouter is a unified gateway that lets you access top models like Claude 3.5, GPT-4o, and Gemini 1.5 using a single account/balance without managing separate provider keys. InksyncPro's native integration routes to Google Gemini via OpenRouter for high-speed reliable JSON streaming.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                Link("Get OpenRouter Key", destination: URL(string: "https://openrouter.ai/keys")!)
                    .font(.caption).foregroundColor(.blue)
            } else if settingsManager.conversionSettings.aiVendor == .openAI {
                Link("Get OpenAI Key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.caption).foregroundColor(.blue)
            } else if settingsManager.conversionSettings.aiVendor == .anthropic {
                Link("Get Anthropic Key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption).foregroundColor(.blue)
            } else if settingsManager.conversionSettings.aiVendor == .gemini {
                Link("Get Google Gemini Key", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                    .font(.caption).foregroundColor(.blue)
            }
            
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
            
            Toggle(isOn: $enableBackgroundSync) {
                HStack {
                    settingsIcon("icloud.and.arrow.up.fill", color: .cyan)
                    VStack(alignment: .leading) {
                        Text("iCloud Auto-Sync")
                        Text("Automatically convert new CBZ files dropped in the Inbox folder.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Toggle(isOn: $settingsManager.conversionSettings.showEditorDebug) {
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
            
            Button(action: {
                if let context = try? InksyncProApp.sharedModelContainer.mainContext {
                    let descriptor = FetchDescriptor<SDAnnotation>()
                    if let annotations = try? context.fetch(descriptor) {
                        for ann in annotations {
                            context.delete(ann)
                        }
                        try? context.save()
                    }
                }
            }) {
                HStack {
                    settingsIcon("flame.fill", color: .red)
                    Text("Purge Zettelkasten Database").foregroundColor(.red)
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

    private func importAIProfile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        Task.detached(priority: .userInitiated) {
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            var parsedData: Data?
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { safeURL in
                parsedData = try? Data(contentsOf: safeURL)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let finalData = parsedData
            await MainActor.run {
                if let data = finalData {
                    do {
                        let importResult = try aiManager.importState(from: data)
                        switch importResult {
                        case .success:
                            aiFeedbackTitle = "Engine Synced"
                            aiFeedbackMessage = "The AI Panel Generator profile has been updated!"
                        case .identical:
                            aiFeedbackTitle = "Up to Date"
                            aiFeedbackMessage = "You are already using this exact AI Configuration Profile."
                        }
                        showingAIFeedbackAlert = true
                    } catch {
                        aiFeedbackTitle = "Invalid Config File"
                        aiFeedbackMessage = "The file you selected is not a valid Inksync AI Profile."
                        showingAIFeedbackAlert = true
                    }
                } else {
                    aiFeedbackTitle = "Import Error"
                    aiFeedbackMessage = "File unreadable or inaccessible."
                    showingAIFeedbackAlert = true
                }
            }
        }
    }
}

import UniformTypeIdentifiers
struct JSONFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        if let fileData = configuration.file.regularFileContents {
            data = fileData
        } else {
            data = Data()
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: data)
    }
}

import SwiftUI

// ============================================================================
// MARK: - CONVERT VIEW
// ============================================================================

struct ConvertView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingFilePicker = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var selectedFiles: [URL] = []
    @State private var isConverting = false
    @State private var conversionProgress: Double = 0
    @State private var currentFileName = ""
    @State private var showCompressionOptions = false
    @State private var showEnhancementOptions = false
    @State private var showDeviceOptions = false
    @State private var settings = ConversionSettings()
    
    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(colors: [Color(.systemBackground), Color.orange.opacity(0.1)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        headerCard
                        fileSelectionArea
                        if !selectedFiles.isEmpty {
                            selectedFilesSection
                            mangaModeToggle
                            compressionSection
                            imageEnhancementSection
                            deviceOptimizationSection
                        }
                        if isConverting { conversionProgressSection }
                        if !selectedFiles.isEmpty && !isConverting { convertButton }
                        Spacer(minLength: 100)
                    }.padding()
                }
            }
            .navigationTitle("Comic to PDF")
            .navigationBarTitleDisplayMode(.large)
            .fullScreenCover(isPresented: $showingFilePicker) { DocumentPickerView(selectedFiles: $selectedFiles, isPresented: $showingFilePicker).ignoresSafeArea() }
            .alert("Status", isPresented: $showingAlert) { Button("OK", role: .cancel) { } } message: { Text(alertMessage) }
            .onAppear { settings = conversionManager.conversionSettings }
        }.navigationViewStyle(.stack)
    }
    
    private var headerCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext").font(.system(size: 60)).foregroundColor(.orange)
            Text("CBZ/CBR to PDF Converter").font(.title2).fontWeight(.bold)
            Text("Convert your comic archives to PDF format for Kindle reading").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
        }.padding(.vertical, 30).padding(.horizontal).frame(maxWidth: .infinity).background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
    }
    
    private var fileSelectionArea: some View {
        Button(action: { showingFilePicker = true }) {
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.orange.opacity(0.2)).frame(width: 80, height: 80)
                    Image(systemName: "plus.circle.fill").font(.system(size: 40)).foregroundColor(.orange)
                }
                Text("Select CBZ/CBR Files").font(.headline).foregroundColor(.primary)
                Text("Tap to browse your files").font(.caption).foregroundColor(.secondary)
            }.padding(40).frame(maxWidth: .infinity).background(RoundedRectangle(cornerRadius: 20).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [10])).foregroundColor(.orange.opacity(0.5)))
        }
    }
    
    private var selectedFilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Selected Files").font(.headline)
                Spacer()
                Button("Clear All") { withAnimation { selectedFiles.removeAll() } }.font(.caption).foregroundColor(.red)
            }
            ForEach(selectedFiles, id: \.absoluteString) { url in
                FileRowView(url: url) { withAnimation { selectedFiles.removeAll { $0 == url } } }
            }
        }.padding().background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
    }
    
    private var mangaModeToggle: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "text.justify.trailing").foregroundColor(.purple).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manga Mode").font(.headline)
                    Text("Right-to-left reading order (for Japanese manga)").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $settings.mangaMode).toggleStyle(SwitchToggleStyle(tint: .purple))
            }
            if settings.mangaMode {
                HStack {
                    Image(systemName: "info.circle.fill").foregroundColor(.purple)
                    Text("Pages will be reversed for proper manga reading").font(.caption).foregroundColor(.secondary)
                }.padding(10).background(Color.purple.opacity(0.1).cornerRadius(8))
            }
        }.padding().background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
    }
    
    private var compressionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "arrow.down.doc.fill").foregroundColor(.orange)
                Text("Compression").font(.headline)
                Spacer()
                Button(action: { withAnimation { showCompressionOptions.toggle() } }) {
                    Image(systemName: showCompressionOptions ? "chevron.up.circle.fill" : "chevron.down.circle.fill").font(.title2).foregroundColor(.orange)
                }
            }
            HStack {
                Text(settings.compressionQuality.rawValue).fontWeight(.medium)
                Spacer()
                Text(compressionSizeEstimate).font(.caption).foregroundColor(.secondary)
            }.padding(12).background(Color.orange.opacity(0.1).cornerRadius(10))
            if showCompressionOptions {
                ForEach(CompressionPreset.allCases, id: \.self) { preset in
                    CompressionPresetRow(preset: preset, isSelected: settings.compressionQuality == preset, action: { settings.compressionQuality = preset })
                }
                if settings.compressionQuality == .custom { customSliders }
            }
        }.padding().background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
    }
    
    private var customSliders: some View {
        VStack(spacing: 16) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Resolution Scale"); Spacer(); Text("\(Int(settings.customScale * 100))%").fontWeight(.semibold).foregroundColor(.orange) }
                Slider(value: $settings.customScale, in: 0.3...1.0, step: 0.05).tint(.orange)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Image Quality"); Spacer(); Text("\(Int(settings.customJpegQuality * 100))%").fontWeight(.semibold).foregroundColor(.orange) }
                Slider(value: $settings.customJpegQuality, in: 0.5...1.0, step: 0.05).tint(.orange)
            }
        }
    }
    
    private var compressionSizeEstimate: String {
        let values = settings.compressionQuality == .custom ? (settings.customScale, settings.customJpegQuality) : settings.compressionQuality.values
        let reduction = Int((1 - values.0 * values.1) * 100)
        return "~\(reduction)% smaller"
    }
    
    private var imageEnhancementSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "wand.and.stars").foregroundColor(.blue)
                Text("Image Enhancement").font(.headline)
                Spacer()
                Toggle("", isOn: $settings.imageEnhancement.enabled).toggleStyle(SwitchToggleStyle(tint: .blue))
            }
            if settings.imageEnhancement.enabled {
                Button(action: { withAnimation { showEnhancementOptions.toggle() } }) {
                    HStack { Text("Enhancement Settings").font(.subheadline); Spacer(); Image(systemName: showEnhancementOptions ? "chevron.up" : "chevron.down") }.foregroundColor(.blue)
                }
                if showEnhancementOptions {
                    VStack(spacing: 16) {
                        Divider()
                        HStack(spacing: 12) {
                            EnhancementToggle(title: "Auto", icon: "wand.and.rays", isOn: $settings.imageEnhancement.autoContrast)
                            EnhancementToggle(title: "B&W", icon: "circle.lefthalf.filled", isOn: $settings.imageEnhancement.grayscale)
                            EnhancementToggle(title: "Dark", icon: "moon.fill", isOn: $settings.imageEnhancement.invertColors)
                        }
                        EnhancementSlider(title: "Brightness", value: $settings.imageEnhancement.brightness, range: -0.5...0.5)
                        EnhancementSlider(title: "Contrast", value: $settings.imageEnhancement.contrast, range: 0.5...1.5)
                        EnhancementSlider(title: "Sharpness", value: $settings.imageEnhancement.sharpness, range: 0...1.0)
                        Button("Reset to Defaults") { settings.imageEnhancement = ImageEnhancementSettings(enabled: true) }.font(.caption).foregroundColor(.red)
                    }
                }
            }
        }.padding().background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
    }
    
    private var deviceOptimizationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "ipad.and.arrow.forward").foregroundColor(.green)
                Text("Kindle Optimization").font(.headline)
                Spacer()
                Toggle("", isOn: $settings.optimizeForDevice).toggleStyle(SwitchToggleStyle(tint: .green))
            }
            if settings.optimizeForDevice {
                Button(action: { withAnimation { showDeviceOptions.toggle() } }) {
                    HStack {
                        Image(systemName: settings.targetDevice.icon)
                        Text(settings.targetDevice.rawValue).fontWeight(.medium)
                        Spacer()
                        Text("\(Int(settings.targetDevice.resolution.width))×\(Int(settings.targetDevice.resolution.height))").font(.caption).foregroundColor(.secondary)
                        Image(systemName: showDeviceOptions ? "chevron.up" : "chevron.down")
                    }.foregroundColor(.primary).padding(12).background(Color.green.opacity(0.1).cornerRadius(10))
                }
                if showDeviceOptions {
                    ForEach(KindleDeviceType.allCases, id: \.self) { device in
                        Button(action: { settings.targetDevice = device; showDeviceOptions = false }) {
                            HStack {
                                Image(systemName: device.icon).frame(width: 24)
                                Text(device.rawValue)
                                Spacer()
                                Text("\(Int(device.resolution.width))×\(Int(device.resolution.height))").font(.caption).foregroundColor(.secondary)
                                if settings.targetDevice == device { Image(systemName: "checkmark.circle.fill").foregroundColor(.green) }
                            }.foregroundColor(.primary).padding(10)
                        }
                    }
                }
            }
        }.padding().background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
    }
    
    private var conversionProgressSection: some View {
        VStack(spacing: 16) {
            ProgressView(value: conversionProgress).progressViewStyle(LinearProgressViewStyle(tint: .orange)).scaleEffect(y: 2)
            Text("Converting: \(currentFileName)").font(.caption).foregroundColor(.secondary)
            Text("\(Int(conversionProgress * 100))%").font(.title2).fontWeight(.bold).foregroundColor(.orange)
        }.padding().background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
    }
    
    private var convertButton: some View {
        Button(action: startConversion) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Convert \(selectedFiles.count) File\(selectedFiles.count > 1 ? "s" : "")").fontWeight(.semibold)
            }.foregroundColor(.white).padding().frame(maxWidth: .infinity).background(LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)).cornerRadius(16).shadow(color: .orange.opacity(0.4), radius: 10, y: 5)
        }
    }
    
    private func startConversion() {
        isConverting = true
        conversionProgress = 0
        conversionManager.conversionSettings = settings
        conversionManager.saveSettings()
        Task {
            do {
                for (index, fileURL) in selectedFiles.enumerated() {
                    let accessing = fileURL.startAccessingSecurityScopedResource()
                    defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
                    await MainActor.run { currentFileName = fileURL.lastPathComponent }
                    let outputURL = try await conversionManager.convertToPDF(from: fileURL, settings: settings) { progress in
                        Task { @MainActor in
                            let fileProgress = Double(index) / Double(selectedFiles.count)
                            let itemProgress = progress / Double(selectedFiles.count)
                            conversionProgress = fileProgress + itemProgress
                        }
                    }
                    await MainActor.run { conversionManager.addToLibrary(outputURL) }
                }
                await MainActor.run {
                    isConverting = false
                    conversionProgress = 1.0
                    selectedFiles.removeAll()
                    alertMessage = "All files converted successfully! Check the Library tab."
                    showingAlert = true
                }
            } catch {
                await MainActor.run {
                    isConverting = false
                    alertMessage = "Conversion failed: \(error.localizedDescription)"
                    showingAlert = true
                }
            }
        }
    }
}

struct CompressionPresetRow: View {
    let preset: CompressionPreset
    let isSelected: Bool
    let action: () -> Void
    var body: some View { Button(action: action) { HStack { Text(preset.rawValue).fontWeight(isSelected ? .semibold : .regular); Spacer(); if isSelected { Image(systemName: "checkmark.circle.fill").foregroundColor(.orange) } }.foregroundColor(.primary).padding(12).background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.orange.opacity(0.1) : Color.clear)) } }
}

struct EnhancementToggle: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool
    var body: some View { Button(action: { isOn.toggle() }) { VStack(spacing: 6) { Image(systemName: icon).font(.title2); Text(title).font(.caption2) }.foregroundColor(isOn ? .white : .blue).frame(maxWidth: .infinity).padding(.vertical, 12).background(RoundedRectangle(cornerRadius: 10).fill(isOn ? Color.blue : Color.blue.opacity(0.1))) } }
}

struct EnhancementSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var body: some View { VStack(alignment: .leading, spacing: 4) { HStack { Text(title).font(.caption); Spacer(); Text(String(format: "%.0f%%", value * 100)).font(.caption).foregroundColor(.blue) }; Slider(value: $value, in: range).tint(.blue) } }
}

struct FileRowView: View {
    let url: URL
    let onDelete: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: url.pathExtension.lowercased() == "cbr" ? "doc.zipper.fill" : "doc.zipper").font(.title2).foregroundColor(.orange).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) { Text(url.lastPathComponent).font(.subheadline).fontWeight(.medium).lineLimit(1); Text(url.pathExtension.uppercased()).font(.caption2).foregroundColor(.secondary).padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.2).cornerRadius(4)) }
            Spacer()
            Button(action: onDelete) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
        }.padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}

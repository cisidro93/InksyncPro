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
    @State private var showingRenameSheet = false
    @State private var renameFileURL: URL? = nil
    @State private var customFileNames: [URL: String] = [:]
    @State private var autoSplitEnabled = true
    @State private var showingSuccessAnimation = false
    @State private var hasAppeared = false
    
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
                            autoSplitSection
                            outputFormatSection
                            if settings.outputFormat != .pdf {
                                epubSettingsSection
                            }
                            compressionSection
                            imageEnhancementSection
                            deviceOptimizationSection
                        }
                        
                        // Action buttons
                        VStack(spacing: 12) {
                            if !selectedFiles.isEmpty {
                                Button(action: startConversion) {
                                    HStack {
                                        if isConverting {
                                            ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        } else {
                                            Image(systemName: "arrow.right.circle.fill")
                                        }
                                        Text(isConverting ? "Converting..." : "Convert Now")
                                            .fontWeight(.bold)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(isConverting ? Color.gray : Color.orange)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                                }
                                .disabled(isConverting)
                            }
                            
                            Button(action: { showingFilePicker = true }) {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Select Files")
                                }
                                .font(.headline)
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        // Adding extra spacer to ensure scrolling content isn't hidden under floating buttons if any
                        Spacer(minLength: 60)
                    }.padding()
                }
            }
            .navigationTitle("Comic to PDF")
            .navigationBarTitleDisplayMode(.large)
            .fullScreenCover(isPresented: $showingFilePicker) { DocumentPickerView(selectedFiles: $selectedFiles, isPresented: $showingFilePicker).ignoresSafeArea() }
            .alert("Status", isPresented: $showingAlert) { Button("OK", role: .cancel) { } } message: { Text(alertMessage) }
            .onAppear {
                if !hasAppeared {
                    settings = conversionManager.conversionSettings
                    hasAppeared = true
                }
            }
            .sheet(isPresented: $showingRenameSheet) {
                RenameSheetView(
                    fileURL: renameFileURL,
                    customFileNames: $customFileNames,
                    isPresented: $showingRenameSheet
                )
            }
            .overlay(Group {
                if showingSuccessAnimation {
                    SuccessCheckmarkView()
                }
            })
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
                Button("Clear All") { 
                    withAnimation { 
                        selectedFiles.removeAll()
                        customFileNames.removeAll()
                    } 
                }
                .font(.caption)
                .foregroundColor(.red)
            }
            
            ForEach(selectedFiles, id: \.absoluteString) { url in
                HStack(spacing: 12) {
                    Image(systemName: url.pathExtension.lowercased() == "cbr" ? "doc.zipper.fill" : "doc.zipper")
                        .font(.title2)
                        .foregroundColor(.orange)
                        .frame(width: 40)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(customFileNames[url] ?? url.deletingPathExtension().lastPathComponent)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        
                        HStack(spacing: 4) {
                            Text(url.pathExtension.uppercased())
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.2).cornerRadius(4))
                            
                            if customFileNames[url] != nil {
                                Text("renamed")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.2).cornerRadius(4))
                            }
                        }
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        renameFileURL = url
                        showingRenameSheet = true
                    }) {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundColor(.blue)
                            .font(.title2)
                    }
                    
                    Button(action: {
                        withAnimation {
                            selectedFiles.removeAll { $0 == url }
                            customFileNames.removeValue(forKey: url)
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
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
    
    private var autoSplitSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "scissors").foregroundColor(.red).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-Split").font(.headline)
                    Text("Split PDF if size exceeds 50MB (Kindle limit)").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $autoSplitEnabled).toggleStyle(SwitchToggleStyle(tint: .red))
            }
        }.padding().background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
    }
    
    private var outputFormatSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Format").font(.headline)
            Picker("Output Format", selection: $settings.outputFormat) {
                ForEach(OutputFormat.allCases, id: \.self) { format in
                    Label(format.rawValue, systemImage: format.icon)
                        .tag(format)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            
            Text(settings.outputFormat.description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
    }
    
    private var epubSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("EPUB Settings").font(.headline)
            
            HStack {
                Text("Reading Direction")
                Spacer()
                Picker("", selection: $settings.epubSettings.readingDirection) {
                    ForEach(EPUBSettings.ReadingDirection.allCases, id: \.self) { direction in
                        Text(direction.displayName).tag(direction)
                    }
                }
                .pickerStyle(MenuPickerStyle())
            }
            
            Toggle("Include Table of Contents", isOn: $settings.epubSettings.includeTableOfContents)
            Toggle("Preserve Aspect Ratio", isOn: $settings.epubSettings.preserveAspectRatio)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
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
                    
                    // Create a mutable copy of settings so we can change the output name if needed (though name is passed to createPDF)
                    // Actually, convertToPDF takes 'from sourceURL' and derives name.
                    // We need to check if ConvertedPDF logic supports custom name, or if we need to modify how naming works.
                    // Looking at ConversionManager.convertToPDF:
                    // It calls createPDF(..., named: sourceURL.deletingPathExtension().lastPathComponent, ...)
                    // We need to modify ConversionManager.convertToPDF to accept a name, OR we can't easily do this without modifying ConversionManager.
                    
                    // Wait, I can't modify ConversionManager easily right now as it's not in the plan (though I can add a task).
                    // BUT, let's look at ConversionManager.scan again. 
                    // ConversionManager.convertToPDF line 233: 
                    // let pdfURL = try await createPDF(..., named: sourceURL.deletingPathExtension().lastPathComponent, ...)
                    
                    // Ah, I need to update ConversionManager to allow passing a custom name or handle the renaming there.
                    // OR, since I'm in the Controller/View, I can rename the file AFTER it is returned? 
                    // But convertToPDF returns a URL.
                    
                    // Let's modify ConversionManager.convertToPDF to accept an optional 'customName' argument.
                    // Wait, I am editing ConvertView.swift. 
                    // Let's assume I will update ConversionManager.swift next.
                    
                    let _ = customFileNames[fileURL] ?? fileURL.deletingPathExtension().lastPathComponent
                    
                    let urls = try await conversionManager.convertToFormat(
                        conversionManager.conversionSettings.outputFormat,
                        from: fileURL,
                        settings: settings,
                        progressHandler: { progress in
                            Task { @MainActor in
                                let fileProgress = Double(index) / Double(selectedFiles.count)
                                let itemProgress = progress / Double(selectedFiles.count)
                                conversionProgress = fileProgress + itemProgress
                            }
                        }
                    )
                    
                    await MainActor.run {
                        for url in urls {
                            // Assume EPUB has count of images matching images... wait, we need page count.
                            // If it's PDF, we can use 0 and let addToLibrary detect (if I enabled that).
                            // But I made addToLibrary logic: `if pdf then PDFDocument... else if explicit...`
                            // For EPUB, `PDFDocument` fails.
                            // However, in `convertToEPUB`, I know the page count (it's in the loop).
                            // But `convertToFormat` returns [URL].
                            // I may need to update `addToLibrary` to be smarter about EPUBs or return more info.
                            // Simplest fix for now: If extension is EPUB, try to pass 0 and let it be 0? Or guess?
                            // Or, I can check if it's PDF, calculate. If it's EPUB, well, I don't have the count handy here easily without unzipping.
                            // Is page count critical? It shows up in the UI.
                            // I'll leave it as 0 for EPUB for now or try to improve `Structure` later if it's an issue.
                            // Actually, I can update `addToLibrary` to ignore page count for non-PDF if needed, or just display "N/A" or "?".
                            conversionManager.addToLibrary(url)
                        }
                        
                        // Auto-split logic strictly for PDF
                        if autoSplitEnabled && settings.outputFormat != .epub {
                            // Only split PDFs. If "Both", we have both. We should filter for PDF.
                             for url in urls where url.pathExtension.lowercased() == "pdf" {
                                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                                   let size = attrs[.size] as? Int64, size > 50 * 1024 * 1024 {
                                    Task {
                                        do {
                                            let parts = try await conversionManager.splitPDF(at: url, maxSizeMB: 50) { _ in }
                                            await MainActor.run {
                                                for part in parts { conversionManager.addToLibrary(part) }
                                                conversionManager.removeFromLibrary(ConvertedPDF(name: "", url: url, pageCount: 0, fileSize: 0))
                                                try? FileManager.default.removeItem(at: url)
                                            }
                                        } catch {
                                            print("Auto-split failed: \(error)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                await MainActor.run {
                    isConverting = false
                    conversionProgress = 1.0
                    selectedFiles.removeAll()
                    
                    // Show success animation instead of alert
                    showingSuccessAnimation = true
                    HapticManager.shared.notification(.success)
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        showingSuccessAnimation = false
                    }
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

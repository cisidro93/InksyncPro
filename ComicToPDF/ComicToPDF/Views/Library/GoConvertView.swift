import SwiftUI
import UniformTypeIdentifiers
import CoreImage

// MARK: - Quick Merge Sheet (reorderable, Go-native)
private struct GoQuickMergeSheet: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    
    @State var mergeOrder: [ConvertedPDF]
    @State var outputName: String
    var mangaMode: Bool
    var onMergeComplete: ([URL]) -> Void
    
    @State private var isMerging = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(mergeOrder) { pdf in
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal").foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pdf.name).font(.subheadline).lineLimit(1)
                                Text(pdf.formattedSize).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .onMove { indices, offset in mergeOrder.move(fromOffsets: indices, toOffset: offset) }
                } header: {
                    HStack {
                        Text("Merge Order")
                        Spacer()
                        EditButton().font(.caption)
                    }
                } footer: {
                    Text("Drag ≡ to reorder. Top file becomes Chapter 1.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                Section(header: Text("Output Name")) {
                    TextField("e.g. My Comic Omnibus", text: $outputName).autocorrectionDisabled()
                }
            }
            .navigationTitle("Quick Merge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge & Send") { runMerge() }
                        .fontWeight(.bold).disabled(isMerging || mergeOrder.count < 2)
                }
            }
            .overlay {
                if isMerging {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView().scaleEffect(1.5).tint(.white)
                            Text("Merging…").font(.headline).foregroundColor(.white)
                        }
                        .padding(32).background(.ultraThinMaterial).cornerRadius(16)
                    }
                }
            }
            .alert("Merge Failed", isPresented: Binding<Bool>(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "An unknown error occurred.")
            }
        }
    }
    
    private func runMerge() {
        isMerging = true
        let name = outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Go Merge" : outputName
        let files = mergeOrder
        Task {
            Logger.shared.log("Quick Merge started: \(files.count) files → \"\(name)\"", category: "GoUI")
            await conversionManager.mergePDFs(files, outputName: name, mangaMode: mangaMode)
            await MainActor.run {
                isMerging = false
                let merged = conversionManager.convertedPDFs
                    .filter { $0.name.contains(name) }
                    .compactMap { FileManager.default.fileExists(atPath: $0.url.path) ? $0.url : nil }
                if merged.isEmpty {
                    Logger.shared.log("Quick Merge: output not found after merge", category: "GoUI", type: .warning)
                    errorMessage = "Merge completed but output could not be located. Check Settings → Logs."
                } else {
                    Logger.shared.log("Quick Merge complete", category: "GoUI")
                    onMergeComplete(merged)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - GoConvertView
struct GoConvertView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject private var queueManager = ConversionQueueManager.shared
    
    @State private var selectedFiles: [URL] = []
    @State private var isTargetingManga = true
    @State private var useLiquidEInk = true
    @State private var compressionQuality: CompressionPreset = .high
    @State private var showingFilePicker = false
    @State private var shareItems: [URL] = []
    @State private var showingShareSheet = false
    @State private var pdfToRename: ConvertedPDF? = nil
    @State private var renameText: String = ""
    @State private var renameError: String? = nil
    @State private var showingMergeSheet = false
    
    // ✅ RELIABLE: Match completed Go conversions by source file stem against library
    // This bypasses the addedByMode race condition entirely.
    private var goConvertedFiles: [ConvertedPDF] {
        let stems = queueManager.completedGoSourceStems
        guard !stems.isEmpty else { return [] }
        return conversionManager.convertedPDFs.filter { pdf in
            let pdfStem = pdf.url.deletingPathExtension().lastPathComponent
            return stems.contains { stem in
                pdfStem.localizedCaseInsensitiveContains(stem) ||
                stem.localizedCaseInsensitiveContains(pdfStem)
            }
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Go Convert")
                    .font(.largeTitle).bold().padding(.top, 40)
                
                // MARK: Drop Zone
                Button { showingFilePicker = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.blue.opacity(0.5), style: StrokeStyle(lineWidth: 3, dash: [10]))
                            .background(Color.blue.opacity(0.05).cornerRadius(24))
                        VStack(spacing: 12) {
                            Image(systemName: "plus.square.dashed").font(.system(size: 60)).foregroundStyle(.blue)
                            if selectedFiles.isEmpty {
                                Text("Tap to Select Files").font(.title3).bold().foregroundStyle(.primary)
                                Text("or Drag & Drop CBZ/PDF here").font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                Text("\(selectedFiles.count) File(s) Selected")
                                    .font(.title3).bold().foregroundStyle(.blue)
                                // ✅ Show actual filenames, not just a count
                                ForEach(selectedFiles.prefix(3), id: \.self) { url in
                                    Text(url.lastPathComponent)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if selectedFiles.count > 3 {
                                    Text("+ \(selectedFiles.count - 3) more…")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
                .padding(.horizontal, 32)
                .sheet(isPresented: $showingFilePicker) {
                    DocumentPicker(onDocumentsPicked: { self.selectedFiles = $0 })
                }
                
                // MARK: Settings
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Content Type").font(.headline)
                        Picker("Content Type", selection: $isTargetingManga) {
                            Text("Manga (Right-to-Left)").tag(true)
                            Text("Western Comic (L-to-R)").tag(false)
                        }.pickerStyle(.segmented)
                    }.padding(.horizontal, 32)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Target Device").font(.headline)
                        Picker("Target Device", selection: $conversionManager.conversionSettings.targetDeviceProfile) {
                            ForEach(TargetDeviceProfile.allCases) { profile in Text(profile.rawValue).tag(profile) }
                        }
                        .pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                        .padding().background(Color(.secondarySystemBackground)).cornerRadius(12)
                    }.padding(.horizontal, 32)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Image Quality").font(.headline)
                        Picker("Image Quality", selection: $compressionQuality) {
                            ForEach(CompressionPreset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                        .padding().background(Color(.secondarySystemBackground)).cornerRadius(12)
                    }.padding(.horizontal, 32)
                    
                    Toggle(isOn: $useLiquidEInk) {
                        VStack(alignment: .leading) {
                            Text("✨ Liquid E-Ink Optimization").font(.headline)
                            Text("Auto-levels, unsharp masking & gamma for perfect E-Ink contrast.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding().background(Color(.secondarySystemBackground)).cornerRadius(12)
                    .padding(.horizontal, 32)
                }
                
                // MARK: Queue Hub / Convert Button
                Group {
                    if queueManager.isProcessing || queueManager.activeItem != nil {
                        // The UI is now handled by the Immersive Overlay on top, 
                        // but we leave this block here so the view structure is maintained and buttons are disabled.
                        VStack(spacing: 12) {
                            Text("Queue Processing...")
                                .font(.headline).foregroundStyle(.secondary)
                            
                            Button(role: .destructive) { queueManager.cancelAll() } label: {
                                Text("Cancel Queue").bold()
                                    .frame(maxWidth: 200).padding(.vertical, 8)
                                    .background(Color.red.opacity(0.15)).foregroundColor(.red).cornerRadius(10)
                            }
                        }
                        .padding(.horizontal, 32)
                    } else {
                        Button { startGoConversion() } label: {
                            Text("Add to Conversion Queue")
                                .font(.title2).bold()
                                .frame(maxWidth: 400).padding()
                                .background(selectedFiles.isEmpty ? Color.blue.opacity(0.5) : Color.blue)
                                .foregroundColor(.white).cornerRadius(16)
                        }
                        .disabled(selectedFiles.isEmpty)
                    }
                }
                
                // MARK: Recently Converted Panel
                if !goConvertedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Ready to Send", systemImage: "checkmark.circle.fill")
                                .font(.headline).foregroundColor(.green)
                            Spacer()
                            Text("\(goConvertedFiles.count) file\(goConvertedFiles.count == 1 ? "" : "s")")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 32)
                        
                        ForEach(goConvertedFiles) { pdf in
                            HStack(spacing: 12) {
                                Image(systemName: "doc.fill").font(.title2).foregroundStyle(.blue).frame(width: 40)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(pdf.name).font(.subheadline).fontWeight(.medium).lineLimit(1)
                                    Text(pdf.formattedSize).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    pdfToRename = pdf
                                    renameText = pdf.url.deletingPathExtension().lastPathComponent
                                } label: {
                                    Image(systemName: "pencil").foregroundColor(.secondary)
                                        .padding(8).background(Color(.tertiarySystemBackground)).cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                ShareLink(item: pdf.url) {
                                    Label("Send", systemImage: "paperplane.fill")
                                        .font(.caption).fontWeight(.semibold)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(Color.blue).foregroundColor(.white).cornerRadius(20)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 10).padding(.horizontal, 16)
                            .background(Color(.secondarySystemBackground)).cornerRadius(12)
                            .padding(.horizontal, 32)
                        }
                        
                        if goConvertedFiles.count > 1 {
                            VStack(spacing: 10) {
                                ShareLink(items: goConvertedFiles.map { $0.url }) {
                                    Label("Share All \(goConvertedFiles.count) Files", systemImage: "square.and.arrow.up")
                                        .font(.subheadline).fontWeight(.semibold)
                                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                                        .background(Color.blue.opacity(0.12)).foregroundColor(.blue).cornerRadius(12)
                                }
                                Button { showingMergeSheet = true } label: {
                                    Label("Merge & Send to Kindle", systemImage: "arrow.triangle.merge")
                                        .font(.subheadline).fontWeight(.semibold)
                                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                                        .background(Color.green).foregroundColor(.white).cornerRadius(12)
                                }
                            }
                            .padding(.horizontal, 32)
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                Spacer(minLength: 40)
            }
        }
        .disabled(queueManager.isProcessing)
        .overlay(
            Group {
                if queueManager.isProcessing, let activeItem = queueManager.activeItem {
                    ImmersiveConversionOverlay(
                        pdfName: activeItem.sourceURL.lastPathComponent,
                        customProgress: queueManager.currentProgress,
                        customMessage: queueManager.statusMessage
                    )
                    .transition(.opacity.animation(.easeInOut))
                }
            }
        )
        .sheet(isPresented: $showingShareSheet) { ShareSheet(activityItems: shareItems) }
        .sheet(isPresented: $showingMergeSheet) {
            GoQuickMergeSheet(
                mergeOrder: Array(goConvertedFiles),
                outputName: "Go Merge \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none))",
                mangaMode: isTargetingManga
            ) { mergedURLs in
                shareItems = mergedURLs
                showingShareSheet = true
            }
            .environmentObject(conversionManager)
        }
        .alert("Rename File", isPresented: Binding<Bool>(
            get: { pdfToRename != nil },
            set: { if !$0 { pdfToRename = nil } }
        )) {
            TextField("File name", text: $renameText).autocorrectionDisabled()
            Button("Rename") { applyRename() }
            Button("Cancel", role: .cancel) { pdfToRename = nil }
        } message: { Text("File extension will be preserved automatically.") }
        .alert("Rename Failed", isPresented: Binding<Bool>(
            get: { renameError != nil },
            set: { if !$0 { renameError = nil } }
        )) {
            Button("OK", role: .cancel) { renameError = nil }
        } message: { Text(renameError ?? "An unknown error occurred.") }
    }
    
    // MARK: - Actions
    private func applyRename() {
        guard let pdf = pdfToRename else { return }
        let ext = pdf.url.pathExtension
        let safeName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty else { pdfToRename = nil; return }
        let newFilename = "\(safeName).\(ext)"
        let newURL = pdf.url.deletingLastPathComponent().appendingPathComponent(newFilename)
        do {
            try FileManager.default.moveItem(at: pdf.url, to: newURL)
            if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                conversionManager.convertedPDFs[idx].name = newFilename
                conversionManager.saveLibrary()
            }
            // Update any matching stem in queueManager
            let oldStem = pdf.url.deletingPathExtension().lastPathComponent
            if let stemIdx = queueManager.completedGoSourceStems.firstIndex(of: oldStem) {
                queueManager.completedGoSourceStems[stemIdx] = safeName
            }
            Logger.shared.log("Renamed \"\(pdf.name)\" → \"\(newFilename)\"", category: "GoUI")
        } catch {
            let msg = "Rename failed: \(error.localizedDescription)"
            Logger.shared.log(msg, category: "GoUI", type: .error)
            renameError = msg
        }
        pdfToRename = nil
    }
    
    private func startGoConversion() {
        guard !selectedFiles.isEmpty else { return }
        var settingsForGo = conversionManager.conversionSettings
        settingsForGo.mangaMode = isTargetingManga
        settingsForGo.optimizeForDevice = true
        settingsForGo.compressionQuality = compressionQuality
        settingsForGo.outputFormat = .epub
        settingsForGo.outputPipeline = .standard
        settingsForGo.splitMode = .web
        if useLiquidEInk {
            settingsForGo.imageEnhancement.autoContrast = true
            settingsForGo.imageEnhancement.sharpness = 0.5
            settingsForGo.imageEnhancement.gamma = 0.8
        } else {
            settingsForGo.imageEnhancement = .init()
        }
        Logger.shared.log("Go conversion queued: \(selectedFiles.count) file(s)", category: "GoUI")
        for file in selectedFiles { queueManager.enqueue(url: file, settings: settingsForGo, mode: .go) }
        selectedFiles.removeAll()
    }
    
    private func formatTime(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: interval) ?? "00:00"
    }
}

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
    @EnvironmentObject var settingsManager: AppSettingsManager
    @ObservedObject private var queueManager = ConversionQueueManager.shared
    
    @State private var selectedFiles: [URL] = []
    @StateObject private var viewModel = ConversionViewModel()
    @State private var showingActionSheet = false
    @State private var shareItems: [URL] = []
    @State private var showingShareSheet = false
    @State private var pdfToRename: ConvertedPDF? = nil
    @State private var renameText: String = ""
    @State private var renameError: String? = nil
    @State private var showingMergeSheet = false

    private var previewPDF: ConvertedPDF? {
        guard let url = selectedFiles.first else { return nil }
        return ConvertedPDF(
            id: UUID(),
            name: url.lastPathComponent,
            url: url,
            pageCount: 10,
            fileSize: 0,
            metadata: PDFMetadata(title: url.deletingPathExtension().lastPathComponent)
        )
    }

    private var dummyPDF: ConvertedPDF {
        ConvertedPDF(
            id: UUID(),
            name: "Dummy.pdf",
            url: URL(fileURLWithPath: ""),
            pageCount: 1,
            fileSize: 0,
            metadata: PDFMetadata(title: "Dummy")
        )
    }
    
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
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    dropZone
                    settingsCards
                    convertButton
                    if !goConvertedFiles.isEmpty { readyToSendPanel }
                    Spacer(minLength: 40)
                }
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 80) }
            .navigationTitle("Go Convert")
            .navigationBarTitleDisplayMode(.large)
        }
        .overlay {
            if queueManager.isProcessing, let activeItem = queueManager.activeItem {
                ImmersiveConversionOverlay(
                    pdfName: activeItem.sourceURL.lastPathComponent,
                    customProgress: queueManager.currentProgress,
                    customMessage: queueManager.statusMessage
                )
                .transition(.opacity.animation(.easeInOut))
            }
        }
        .sheet(isPresented: $showingShareSheet) { ShareSheet(activityItems: shareItems) }
        .sheet(isPresented: $showingMergeSheet) {
            GoQuickMergeSheet(
                mergeOrder: Array(goConvertedFiles),
                outputName: "Go Merge \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none))",
                mangaMode: viewModel.isMangaMode
            ) { mergedURLs in
                shareItems = mergedURLs
                showingShareSheet = true
            }
            .environmentObject(conversionManager)
        }
        .sheet(isPresented: $viewModel.showingPreview) {
            if let pdf = previewPDF {
                PrecisionCanvasView(pdf: pdf, pageIndex: .constant(3), totalCount: pdf.pageCount, conversionManager: conversionManager)
            }
        }
        .sheet(isPresented: $viewModel.showingCalibreGuide) {
            CalibreGuideView()
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
        .onAppear {
            viewModel.isMangaMode = settingsManager.conversionSettings.mangaMode
            viewModel.selectedPipeline = settingsManager.conversionSettings.outputPipeline
        }
        .onChange(of: selectedFiles) { _, files in
            if let first = files.first {
                let lowerName = first.lastPathComponent.lowercased()
                if lowerName.contains("manga") || lowerName.contains("chapter") || lowerName.contains("ch.") || lowerName.contains("raw") {
                    viewModel.isMangaMode = true
                } else if lowerName.contains("issue") || lowerName.contains("comic") || lowerName.contains("marvel") || lowerName.contains("dc") {
                    viewModel.isMangaMode = false
                }
            }
        }
    }

    // MARK: - Drop Zone
    @ViewBuilder
    private var dropZone: some View {
        Button {
            ImportCoordinator.present(type: .unified) { urls in processPickedFiles(urls) }
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.blue.opacity(0.15))
                    .frame(width: 150, height: 150)
                    .blur(radius: 40)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .background(Color.inkSurfaceRaised.opacity(0.5).cornerRadius(24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Theme.blue.opacity(0.4), Theme.blue.opacity(0.1)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Theme.blue.opacity(0.15), radius: 20, y: 10)
                VStack(spacing: 16) {
                    ZStack {
                        Circle().fill(Theme.blue.opacity(0.1)).frame(width: 64, height: 64)
                        Image(systemName: "square.and.arrow.down.on.square.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.blue.gradient)
                    }
                    if selectedFiles.isEmpty {
                        VStack(spacing: 4) {
                            Text("Tap to Select Files")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Theme.text)
                            Text("or Drag & Drop CBZ/PDF here")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else {
                        VStack(spacing: 6) {
                            Text("\(selectedFiles.count) File(s) Selected")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Theme.blue)
                            VStack(spacing: 4) {
                                ForEach(selectedFiles.prefix(3), id: \.self) { url in
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(1)
                                        .padding(.horizontal, 12).padding(.vertical, 4)
                                        .background(Theme.blue.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                            }
                            if selectedFiles.count > 3 {
                                Text("+ \(selectedFiles.count - 3) more…")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                }
                .padding(.vertical, 32)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: - Settings Cards
    @ViewBuilder
    private var settingsCards: some View {
        VStack(spacing: 16) {
            // Source details
            InkCard(header: "Source Details") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Auto-Split")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.inkTextSecondary)
                    Picker("", selection: $settingsManager.conversionSettings.splitMode) {
                        ForEach(FileSizeSplitMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            // Output Format
            InkCard(header: "Output Format") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Target Format")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.inkTextSecondary)
                    Picker("", selection: $settingsManager.conversionSettings.outputFormat) {
                        ForEach(OutputFormat.allCases) { format in
                            Label(format.rawValue, systemImage: format.icon).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settingsManager.conversionSettings.outputFormat) { _, newFormat in
                        if newFormat != .epub {
                            viewModel.selectedPipeline = .standard
                            viewModel.applyPipeline(.standard, to: &settingsManager.conversionSettings)
                        }
                    }
                }
                Divider().overlay(Color.inkBorderSubtle)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Image Quality")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.inkTextSecondary)
                    Picker("", selection: $settingsManager.conversionSettings.compressionQuality) {
                        ForEach(CompressionPreset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }

            // Hardware Optimisation
            InkCard(header: "Hardware Optimisation") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Target Device")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.inkTextSecondary)
                    Picker("", selection: $settingsManager.conversionSettings.targetDeviceProfile) {
                        ForEach(TargetDeviceProfile.allCases) { device in
                            Text(device.rawValue).tag(device)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.inkBlue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.inkSurfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Divider().overlay(Color.inkBorderSubtle)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("E-Ink High Contrast Filter")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.inkTextPrimary)
                        Text("Maximises readability on greyscale e-ink displays")
                            .font(.system(size: 12))
                            .foregroundColor(.inkTextSecondary)
                    }
                    Spacer()
                    Toggle("", isOn: $settingsManager.conversionSettings.optimizeForDevice)
                        .labelsHidden()
                        .tint(.inkBlue)
                }
            }

            // Export Pipeline (EPUB only)
            if settingsManager.conversionSettings.outputFormat == .epub {
                InkCard(header: "EPUB Export Mode") {
                    VStack(spacing: 10) {
                        ForEach(OutputPipeline.allCases) { pipeline in
                            let pdf = previewPDF ?? dummyPDF
                            let isDisabled = viewModel.pipelineIsDisabled(pipeline, for: pdf, format: settingsManager.conversionSettings.outputFormat)
                            Button(action: {
                                if !isDisabled {
                                    viewModel.selectedPipeline = pipeline
                                    viewModel.applyPipeline(pipeline, to: &settingsManager.conversionSettings)
                                }
                            }) {
                                PipelineCardView(
                                    pipeline: pipeline,
                                    isDisabled: isDisabled,
                                    isSelected: viewModel.selectedPipeline == pipeline,
                                    viewModel: viewModel,
                                    currentFormat: settingsManager.conversionSettings.outputFormat
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(queueManager.isProcessing || isDisabled)
                            .opacity(isDisabled || queueManager.isProcessing ? 0.55 : 1.0)
                        }

                        if viewModel.selectedPipeline == .proPanel {
                            VStack(spacing: 8) {
                                if let pdf = previewPDF {
                                    Button(action: { viewModel.showingPreview = true }) {
                                        Label("Preview Panel Detection (Page 4)", systemImage: "eye")
                                            .font(.system(size: 14))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(Color.inkSurfaceRaised)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .foregroundColor(.inkTextPrimary)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                                Button(action: { viewModel.showingCalibreGuide = true }) {
                                    Label("How to Sideload to Kindle", systemImage: "questionmark.circle")
                                        .font(.caption)
                                        .foregroundColor(.inkBlue)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }

            // Layout
            InkCard(header: "Layout") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reading Direction")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.inkTextPrimary)
                        Text(viewModel.isMangaMode ? "Right to Left (Manga)" : "Left to Right (Western)")
                            .font(.system(size: 12))
                            .foregroundColor(.inkTextSecondary)
                    }
                    Spacer()
                    Toggle("", isOn: $viewModel.isMangaMode)
                        .labelsHidden()
                        .tint(.inkBlue)
                        .disabled(queueManager.isProcessing)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Convert Button
    @ViewBuilder
    private var convertButton: some View {
        Group {
            if queueManager.isProcessing || queueManager.activeItem != nil {
                VStack(spacing: 12) {
                    Text("Queue Processing...")
                        .font(.headline).foregroundColor(Color.inkTextSecondary)
                    Button(role: .destructive) { queueManager.cancelAll() } label: {
                        Text("Cancel Queue").bold()
                            .frame(maxWidth: 200).padding(.vertical, 10)
                            .background(Color.inkRed.opacity(0.15)).foregroundColor(.inkRed).cornerRadius(10)
                    }
                }
                .padding(.horizontal, 16)
            } else {
                Button { startGoConversion() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.fill")
                        Text("Add to Conversion Queue")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(selectedFiles.isEmpty ? Color.inkTextTertiary : Color.inkBlue)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: selectedFiles.isEmpty ? .clear : Color.inkBlue.opacity(0.3), radius: 10, y: 4)
                    .animation(.easeInOut(duration: 0.2), value: selectedFiles.isEmpty)
                }
                .disabled(selectedFiles.isEmpty)
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Ready To Send Panel
    @ViewBuilder
    private var readyToSendPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("READY TO SEND")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.inkTextSecondary)
                Spacer()
                Text("\(goConvertedFiles.count) file\(goConvertedFiles.count == 1 ? "" : "s")")
                    .font(.caption).foregroundColor(.inkTextTertiary)
            }
            .padding(.horizontal, 20)
            ForEach(goConvertedFiles) { pdf in
                HStack(spacing: 12) {
                    Image(systemName: "doc.fill").font(.title2).foregroundStyle(Theme.blue).frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pdf.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                            .foregroundColor(Theme.text)
                        Text(pdf.formattedSize).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button {
                        pdfToRename = pdf
                        renameText = pdf.url.deletingPathExtension().lastPathComponent
                    } label: {
                        Image(systemName: "pencil").foregroundColor(Theme.textSecondary)
                            .padding(8).background(Theme.surfaceElevated).cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    ShareLink(item: pdf.url) {
                        Label("Send", systemImage: "paperplane.fill")
                            .font(.caption).fontWeight(.semibold)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Theme.blue).foregroundColor(.white).cornerRadius(20)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 12).padding(.horizontal, 16)
                .background(Theme.surface).cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                .padding(.horizontal, 16)
            }
            if goConvertedFiles.count > 1 {
                VStack(spacing: 10) {
                    ShareLink(items: goConvertedFiles.map { $0.url }) {
                        Label("Share All \(goConvertedFiles.count) Files", systemImage: "square.and.arrow.up")
                            .font(.subheadline).fontWeight(.semibold)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.blue.opacity(0.12)).foregroundColor(Theme.blue).cornerRadius(12)
                    }
                    Button { showingMergeSheet = true } label: {
                        Label("Merge & Send to Kindle", systemImage: "arrow.triangle.merge")
                            .font(.subheadline).fontWeight(.semibold)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.green).foregroundColor(.white).cornerRadius(12)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 4)
            }
        }
        .padding(.vertical, 8)
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
    
    private func processPickedFiles(_ urls: [URL]) {
        for url in urls {
            if !self.selectedFiles.contains(where: { $0.lastPathComponent == url.lastPathComponent }) {
                self.selectedFiles.append(url)
            }
        }
    }
    
    private func processPickedFolder(_ folderURL: URL) {
        let isAccessing = folderURL.startAccessingSecurityScopedResource()
        defer { if isAccessing { folderURL.stopAccessingSecurityScopedResource() } }
        
        var foundURLs: [URL] = []
        let validExts = ["cbz", "cbr", "cb7", "cbt", "epub", "zip", "pdf"]
        
        if let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if validExts.contains(fileURL.pathExtension.lowercased()) {
                    foundURLs.append(fileURL)
                }
            }
        }
        
        DispatchQueue.main.async {
            self.processPickedFiles(foundURLs)
        }
    }
    
    private func startGoConversion() {
        guard !selectedFiles.isEmpty else { return }
        var settingsForGo = settingsManager.conversionSettings
        settingsForGo.mangaMode = viewModel.isMangaMode
        viewModel.applyPipeline(viewModel.selectedPipeline, to: &settingsForGo)
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

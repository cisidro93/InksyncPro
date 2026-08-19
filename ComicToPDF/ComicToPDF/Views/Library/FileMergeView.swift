import SwiftUI

@MainActor
class FileMergeViewModel: ObservableObject {
    @Published var mergeOrder: [ConvertedPDF] = []
    @Published var outputName: String = ""
    @Published var author: String = ""
    @Published var mangaMode: Bool = false
    @Published var isProcessing: Bool = false
}

struct FileMergeView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    @StateObject private var viewModel: FileMergeViewModel
    private let initialSelection: Set<UUID>
    
    private var availableFiles: [ConvertedPDF] {
        let mergeIDs = Set(viewModel.mergeOrder.map { $0.id })
        return conversionManager.visiblePDFs   // ✅ All non-private files, including Go conversions
            .filter { !mergeIDs.contains($0.id) }
            .sorted { $0.name < $1.name }
    }
    
    init(initialSelection: Set<UUID> = []) {
        self.initialSelection = initialSelection
        _viewModel = StateObject(wrappedValue: FileMergeViewModel())
    }
    
    var body: some View {
        NavigationStack {
            List {
                // MARK: - Merge Order (Draggable)
                Section {
                    if viewModel.mergeOrder.isEmpty {
                        Label("Tap files below to add them here", systemImage: "arrow.up.doc")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(viewModel.mergeOrder) { pdf in
                            HStack(spacing: 12) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pdf.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(pdf.formattedSize)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    viewModel.mergeOrder.removeAll { $0.id == pdf.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .onMove { indices, offset in
                            viewModel.mergeOrder.move(fromOffsets: indices, toOffset: offset)
                        }
                    }
                } header: {
                    HStack {
                        Text("Merge Order")
                        Spacer()
                        if !viewModel.mergeOrder.isEmpty {
                            Text("\(viewModel.mergeOrder.count) files")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } footer: {
                    if !viewModel.mergeOrder.isEmpty {
                        Text("Drag to reorder chapters. The merged file will follow this exact sequence.")
                            .font(.caption)
                    }
                }
                
                // MARK: - Output Settings
                Section(header: Text("Output Options")) {
                    TextField("Collection Name (e.g., My Omnibus)", text: $viewModel.outputName)
                    TextField("Author / Writer (e.g., Frank Miller)", text: $viewModel.author)
                    Toggle("Manga Mode (Right-to-Left)", isOn: $viewModel.mangaMode)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Pair Front Cover with Page 1", isOn: $settingsManager.conversionSettings.linkCoverAsSpread)
                        Text("Keep OFF for standalone front cover (recommended)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Slice Landscape Spreads into 2 Pages", isOn: $settingsManager.conversionSettings.splitSpreads)
                        Text("Keep OFF for native full-bleed landscape on Kindle & Reader")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                    
                    Picker("Target Device", selection: $settingsManager.conversionSettings.targetDeviceProfile) {
                        ForEach(TargetDeviceProfile.allCases) { device in
                            Text(device.rawValue).tag(device)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    Toggle("E-Ink High Contrast Filter", isOn: $settingsManager.conversionSettings.optimizeForDevice)
                    
                    Picker("Image Quality", selection: $settingsManager.conversionSettings.compressionQuality) {
                        ForEach(CompressionPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    
                    if settingsManager.conversionSettings.compressionQuality == .customTarget {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Target File Size")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int(settingsManager.conversionSettings.targetFileSizeMB)) MB")
                                    .font(.subheadline)
                                    .bold()
                                    .foregroundColor(.blue)
                            }
                            Slider(value: $settingsManager.conversionSettings.targetFileSizeMB, in: 10...1000, step: 10)
                        }
                        .padding(.vertical, 4)
                    }
                    
                    Picker("Smart File Splitting", selection: $settingsManager.conversionSettings.splitMode) {
                        ForEach(FileSizeSplitMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                }
                
                // MARK: - Available Files
                Section(header: Text("Available Files — Tap to Add")) {
                    if availableFiles.isEmpty {
                        Text("All files have been added to the merge order.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(availableFiles) { pdf in
                            Button {
                                viewModel.mergeOrder.append(pdf)
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                        .foregroundColor(.blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pdf.name)
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text(pdf.formattedSize)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Merge Files")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !viewModel.isProcessing {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !viewModel.isProcessing {
                        Button("Merge") {
                            let name = viewModel.outputName.trimmingCharacters(in: .whitespaces).isEmpty ? "Merged Collection" : viewModel.outputName
                            viewModel.isProcessing = true
                            Task {
                                await conversionManager.mergePDFs(
                                    viewModel.mergeOrder,
                                    outputName: name,
                                    mangaMode: viewModel.mangaMode,
                                    customAuthor: viewModel.author
                                )
                                await MainActor.run {
                                    viewModel.isProcessing = false
                                    dismiss()
                                }
                            }
                        }
                        .fontWeight(.bold)
                        .disabled(viewModel.mergeOrder.count < 2)
                    }
                }
            }
            .onAppear {
                if viewModel.mergeOrder.isEmpty && !initialSelection.isEmpty {
                    viewModel.mergeOrder = conversionManager.visiblePDFs.filter { initialSelection.contains($0.id) }
                }
                if viewModel.author.isEmpty, let first = viewModel.mergeOrder.first {
                    let existingAuthor = first.metadata.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? first.metadata.writer?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let a = existingAuthor, !a.isEmpty {
                        viewModel.author = a
                    } else {
                        let fileURL = (try? BookmarkResolver.shared.resolveIfLinked(first)) ?? first.url
                        Task.detached(priority: .userInitiated) {
                            if let comicInfo = ComicInfoParser.parse(from: fileURL), let writer = comicInfo.writer, !writer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                await MainActor.run {
                                    viewModel.author = writer
                                }
                            } else if let epubMeta = await EBookParser.shared.parse(epub: fileURL), !epubMeta.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                await MainActor.run {
                                    viewModel.author = epubMeta.author
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if viewModel.isProcessing {
                    ImmersiveConversionOverlay(
                        pdfName: viewModel.outputName.isEmpty ? "Merged Collection" : viewModel.outputName,
                        customMessage: conversionManager.statusMessage ?? "Merging Files..."
                    )
                }
            }
        }
    }
}

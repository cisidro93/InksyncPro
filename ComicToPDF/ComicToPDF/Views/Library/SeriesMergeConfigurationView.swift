import SwiftUI
import UniformTypeIdentifiers

@MainActor
class SeriesMergeConfigurationViewModel: ObservableObject {
    @Published var itemsToMerge: [ConvertedPDF]
    @Published var outputName: String
    @Published var mangaMode: Bool = false
    @Published var isProcessing: Bool = false
    
    init(itemsToMerge: [ConvertedPDF], outputName: String) {
        self.itemsToMerge = itemsToMerge
        self.outputName = outputName
    }
}

struct SeriesMergeConfigurationView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    
    // Initial configuration
    let sourceFiles: [ConvertedPDF]
    let suggestedName: String?
    
    // State ViewModel
    @StateObject private var viewModel: SeriesMergeConfigurationViewModel
    @State private var draggedItem: ConvertedPDF? = nil
    
    init(sourceFiles: [ConvertedPDF], suggestedName: String? = nil) {
        self.sourceFiles = sourceFiles
        self.suggestedName = suggestedName
        // Default sort by logical name (usually volume/issue number)
        let initialMerge = sourceFiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let initialName = suggestedName ?? ""
        
        _viewModel = StateObject(wrappedValue: SeriesMergeConfigurationViewModel(
            itemsToMerge: initialMerge,
            outputName: initialName
        ))
    }
    
    var body: some View {
        NavigationStack {
            VStack {
                if viewModel.isProcessing {
                    ImmersiveConversionOverlay(
                        pdfName: viewModel.outputName.isEmpty ? "Merged Collection" : viewModel.outputName,
                        customMessage: conversionManager.statusMessage ?? "Merging..."
                    )
                } else {
                    Form {
                        Section(header: Text("Output Volume Configuration"), footer: Text("The merged file will automatically be assigned to the current series.")) {
                            TextField("New Volume Name (e.g., Volume 1)", text: $viewModel.outputName)
                            Toggle("Manga Mode (Right-to-Left)", isOn: $viewModel.mangaMode)
                            Toggle("Link Cover Page as Spread", isOn: $settingsManager.conversionSettings.linkCoverAsSpread)
                            
                            Picker("Image Quality", selection: $settingsManager.conversionSettings.compressionQuality) {
                                ForEach(CompressionPreset.allCases, id: \.self) { preset in
                                    Text("\(preset.rawValue) (Est: \(estimatedSize(for: preset)))").tag(preset)
                                }
                            }
                            
                            Picker("Smart File Splitting", selection: $settingsManager.conversionSettings.splitMode) {
                                ForEach(FileSizeSplitMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                        }
                        .listRowBackground(Color.inkSurface.opacity(0.4))
                        
                        Section(header: Text("Size & Compression Preview")) {
                            HStack {
                                Text("Original Combined Size")
                                    .foregroundColor(.inkTextSecondary)
                                Spacer()
                                Text(formatBytes(totalInputSize))
                                    .foregroundColor(.secondary)
                            }
                            
                            HStack {
                                Text("Estimated Merged Size")
                                    .foregroundColor(.inkTextPrimary)
                                Spacer()
                                Text(formatBytes(estimatedOutputSize))
                                    .bold()
                                    .foregroundColor(.inkAmber)
                            }
                            
                            let splitMode = settingsManager.conversionSettings.splitMode
                            if splitMode != .none {
                                HStack {
                                    Text("Splitting Status")
                                        .foregroundColor(.inkTextPrimary)
                                    Spacer()
                                    if willSplit {
                                        Text("⚠️ Splits into \(estimatedParts) files")
                                            .foregroundColor(.inkAmber)
                                            .bold()
                                    } else {
                                        Text("✅ Fits in 1 file")
                                            .foregroundColor(.inkGreen)
                                            .bold()
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.inkSurface.opacity(0.4))
                        
                        Section(header: Text("Merge Order"), footer: Text("Drag the handles or tap Edit to reorder. The top file will be the first issue in the merged volume.")) {
                            ForEach(viewModel.itemsToMerge) { pdf in
                                pdfRow(for: pdf)
                                    .onDrop(of: [.text], delegate: ReorderDropDelegate(item: pdf, items: $viewModel.itemsToMerge, draggedItem: $draggedItem))
                            }
                            .onMove(perform: moveItems)
                        }
                        .listRowBackground(Color.inkSurface.opacity(0.4))
                        
                        Section {
                            Button {
                                startMerge()
                            } label: {
                                HStack {
                                    Spacer()
                                    Text("Convert & Merge")
                                        .bold()
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .disabled(isMergeDisabled)
                            .foregroundColor(isMergeDisabled ? .gray : .white)
                            .listRowBackground(
                                Group {
                                    if isMergeDisabled {
                                        Color.inkSurface.opacity(0.4)
                                    } else {
                                        LinearGradient(colors: [Color.inkBlue, Color.inkViolet.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                                    }
                                }
                            )
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.inkBackground.ignoresSafeArea())
            .navigationTitle("Configure Merge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !viewModel.isProcessing {
                        Button("Cancel") { dismiss() }
                    }
                }
                // Requires EditButton to easily expose drag handles
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !viewModel.isProcessing {
                        EditButton()
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func pdfRow(for pdf: ConvertedPDF) -> some View {
        HStack {
            if let uiImage = conversionManager.getThumbnail(for: pdf) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 60)
                    .cornerRadius(4)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 40, height: 60)
                    .cornerRadius(4)
                    .overlay(Image(systemName: "doc").foregroundColor(.gray))
            }
            
            VStack(alignment: .leading) {
                Text(pdf.name)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(pdf.formattedSize)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .onDrag {
                    self.draggedItem = pdf
                    return NSItemProvider(object: pdf.id.uuidString as NSString)
                }
        }
    }
    
    private var isMergeDisabled: Bool {
        viewModel.itemsToMerge.count < 2 || viewModel.outputName.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    private var totalInputSize: Int64 {
        viewModel.itemsToMerge.reduce(0) { $0 + $1.fileSize }
    }
    
    private var estimatedOutputSize: Int64 {
        let totalPages = viewModel.itemsToMerge.reduce(0) { $0 + $1.pageCount }
        guard totalPages > 0 else {
            let total = Double(totalInputSize)
            let multiplier: Double
            switch settingsManager.conversionSettings.compressionQuality {
            case .high: multiplier = 0.90
            case .balanced: multiplier = 0.65
            case .compact: multiplier = 0.40
            }
            return Int64(total * multiplier)
        }
        
        let bytesPerPage: Int64
        switch settingsManager.conversionSettings.compressionQuality {
        case .high:
            bytesPerPage = 900 * 1024 // ~900 KB
        case .balanced:
            bytesPerPage = 450 * 1024 // ~450 KB
        case .compact:
            bytesPerPage = 200 * 1024 // ~200 KB
        }
        return Int64(totalPages) * bytesPerPage
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        return String(format: "%.1f MB", mb)
    }
    
    private var willSplit: Bool {
        let limit = settingsManager.conversionSettings.splitMode.limit
        return estimatedOutputSize > limit
    }
    
    private var estimatedParts: Int {
        let limit = settingsManager.conversionSettings.splitMode.limit
        guard limit > 0 else { return 1 }
        let parts = Double(estimatedOutputSize) / Double(limit)
        return Int(ceil(parts))
    }
    
    private func estimatedSize(for preset: CompressionPreset) -> String {
        let totalPages = viewModel.itemsToMerge.reduce(0) { $0 + $1.pageCount }
        guard totalPages > 0 else {
            let total = Double(totalInputSize)
            let multiplier: Double
            switch preset {
            case .high: multiplier = 0.90
            case .balanced: multiplier = 0.65
            case .compact: multiplier = 0.40
            }
            return formatBytes(Int64(total * multiplier))
        }
        
        let bytesPerPage: Int64
        switch preset {
        case .high:
            bytesPerPage = 900 * 1024
        case .balanced:
            bytesPerPage = 450 * 1024
        case .compact:
            bytesPerPage = 200 * 1024
        }
        return formatBytes(Int64(totalPages) * bytesPerPage)
    }
    
    private func moveItems(from source: IndexSet, to destination: Int) {
        viewModel.itemsToMerge.move(fromOffsets: source, toOffset: destination)
    }
    
    private func startMerge() {
        let files = viewModel.itemsToMerge
        let name = viewModel.outputName.trimmingCharacters(in: .whitespaces)
        let mode = viewModel.mangaMode
        
        viewModel.isProcessing = true
        
        Task {
            // Explicitly extract the Series mapping tag to assign the generated merge automatically
            let seriesTag = files.first?.metadata.series
            
            // Execute the bulk engine and implicitly return the generated data payload
            let mergedBooks = await conversionManager.convertAndMerge(sourceFiles: files, outputName: name, mangaMode: mode, overrideSeries: seriesTag)
            
            await MainActor.run {
                // If the Engine produced an array, safely pop it to the UI (already explicitly added to ConversionManager)
                if let newBook = mergedBooks.first {
                    print("Merged Book generated natively: \(newBook.name)")
                    NotificationCenter.default.post(name: Notification.Name("OpenMergedBook"), object: newBook)
                }
                viewModel.isProcessing = false
                dismiss()
            }
        }
    }
}

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
                            
                            Picker("Image Quality", selection: $settingsManager.conversionSettings.compressionQuality) {
                                ForEach(CompressionPreset.allCases, id: \.self) { preset in
                                    Text(preset.rawValue).tag(preset)
                                }
                            }
                            
                            Picker("Smart File Splitting", selection: $settingsManager.conversionSettings.splitMode) {
                                ForEach(FileSizeSplitMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                        }
                        .listRowBackground(Color.inkSurface.opacity(0.4))
                        
                        Section(header: Text("Merge Order"), footer: Text("Drag to reorder. The top file will be the first issue in the merged volume.")) {
                            ForEach(viewModel.itemsToMerge) { pdf in
                                pdfRow(for: pdf)
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
        }
    }
    
    private var isMergeDisabled: Bool {
        viewModel.itemsToMerge.count < 2 || viewModel.outputName.trimmingCharacters(in: .whitespaces).isEmpty
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

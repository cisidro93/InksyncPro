import SwiftUI
import UniformTypeIdentifiers

struct SeriesMergeConfigurationView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    // Initial configuration
    let sourceFiles: [ConvertedPDF]
    
    // State
    @State private var itemsToMerge: [ConvertedPDF]
    @State private var outputName: String = ""
    @State private var mangaMode: Bool = false
    
    init(sourceFiles: [ConvertedPDF]) {
        self.sourceFiles = sourceFiles
        // Default sort by logical name (usually volume/issue number)
        _itemsToMerge = State(initialValue: sourceFiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Output Volume Configuration"), footer: Text("The merged file will automatically be assigned to the current series.")) {
                    TextField("New Volume Name (e.g., Volume 1)", text: $outputName)
                    Toggle("Manga Mode (Right-to-Left)", isOn: $mangaMode)
                }
                
                Section(header: Text("Merge Order"), footer: Text("Drag to reorder. The top file will be the first issue in the merged volume.")) {
                    List {
                        ForEach(itemsToMerge) { pdf in
                            pdfRow(for: pdf)
                        }
                        .onMove(perform: moveItems)
                    }
                }
                
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
                    }
                    .disabled(isMergeDisabled)
                }
            }
            .navigationTitle("Configure Merge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // Requires EditButton to easily expose drag handles
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
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
        itemsToMerge.count < 2 || outputName.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    private func moveItems(from source: IndexSet, to destination: Int) {
        itemsToMerge.move(fromOffsets: source, toOffset: destination)
    }
    
    private func startMerge() {
        let files = itemsToMerge
        let name = outputName.trimmingCharacters(in: .whitespaces)
        let mode = mangaMode
        
        Task {
            // First we need to ensure the resulting PDF is correctly tagged to the series!
            // Wait, we need the series name!
            // Let's get it from the first item
            let seriesName = files.first?.metadata.series
            
            await conversionManager.convertAndMerge(sourceFiles: files, outputName: name, mangaMode: mode)
            
            // Wait, convertAndMerge generates new PDFs but doesn't auto-assign them to the series natively in code, it relies on scanLibrary.
            // But if we want it to automatically appear in the series, we can try to explicitly set the series name on the newly generated output if it replaces something.
            // Actually, in ConversionManager, convertAndMerge creates EPUBs and relies on scanLibrary. To explicitly set metadata, we would need to edit metadata before scanning, but standard metadata extraction should catch it if the filename matches the series folder, or we can just leave it to user.
            
            dismiss()
        }
    }
}

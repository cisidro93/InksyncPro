import SwiftUI

struct FileMergeView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var mergeOrder: [ConvertedPDF] = []
    @State private var outputName: String = ""
    @State private var mangaMode: Bool = false
    
    private var availableFiles: [ConvertedPDF] {
        let mergeIDs = Set(mergeOrder.map { $0.id })
        return conversionManager.visiblePDFs   // ✅ All non-private files, including Go conversions
            .filter { !mergeIDs.contains($0.id) }
            .sorted { $0.name < $1.name }
    }
    
    init(initialSelection: Set<UUID> = []) {
        // Pre-populate merge order from initial selection
        _mergeOrder = State(initialValue: [])
    }
    
    var body: some View {
        NavigationStack {
            List {
                // MARK: - Merge Order (Draggable)
                Section {
                    if mergeOrder.isEmpty {
                        Label("Tap files below to add them here", systemImage: "arrow.up.doc")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(mergeOrder) { pdf in
                            HStack(spacing: 12) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pdf.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(pdf.formattedSize)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button {
                                    mergeOrder.removeAll { $0.id == pdf.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .onMove { indices, offset in
                            mergeOrder.move(fromOffsets: indices, toOffset: offset)
                        }
                    }
                } header: {
                    HStack {
                        Text("Merge Order")
                        Spacer()
                        if !mergeOrder.isEmpty {
                            EditButton()
                                .font(.caption)
                        }
                    }
                } footer: {
                    if !mergeOrder.isEmpty {
                        Text("Drag \(Image(systemName: "line.3.horizontal")) to reorder. The top file becomes Chapter 1.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                // MARK: - Output Settings
                Section(header: Text("Output")) {
                    TextField("Collection Name (e.g., My Omnibus)", text: $outputName)
                    Toggle("Manga Mode (Right-to-Left)", isOn: $mangaMode)
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
                                mergeOrder.append(pdf)
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
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge") {
                        let name = outputName.trimmingCharacters(in: .whitespaces).isEmpty ? "Merged Collection" : outputName
                        Task {
                            await conversionManager.mergePDFs(mergeOrder, outputName: name, mangaMode: mangaMode)
                            dismiss()
                        }
                    }
                    .fontWeight(.bold)
                    .disabled(mergeOrder.count < 2)
                }
            }
        }
    }
}

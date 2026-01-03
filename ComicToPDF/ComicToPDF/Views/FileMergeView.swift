import SwiftUI

struct FileMergeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var selectedPDFs: Set<UUID> = []

    @State private var outputName: String = "Merged Book"
    @State private var isMerging = false
    @State private var targetFormat: OutputFormat = .pdf
    
    // Explicit list passed if triggered from selection
    var preselectedPDFs: Set<UUID>? = nil
    
    var body: some View {
        NavigationView {
            VStack {
                Form {
                    Section(header: Text("Settings")) {
                        TextField("Output Name", text: $outputName)
                        
                        Picker("Output Format", selection: $targetFormat) {
                            ForEach(OutputFormat.allCases) { format in
                                Label(format.rawValue, systemImage: format.icon).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                        
                        if hasMixedTypes {
                            Text("Mixed file types selected. Files will be converted to \(targetFormat.rawValue).")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    
                    Section(header: Text("Select Files to Merge")) {
                        List {
                            ForEach(conversionManager.convertedPDFs) { pdf in
                                HStack {
                                    Image(systemName: selectedPDFs.contains(pdf.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedPDFs.contains(pdf.id) ? .blue : .secondary)
                                    
                                    VStack(alignment: .leading) {
                                        Text(pdf.name)
                                            .lineLimit(1)
                                        Text(pdf.url.pathExtension.uppercased())
                                            .font(.caption2)
                                            .padding(2)
                                            .background(Color.gray.opacity(0.2))
                                            .cornerRadius(4)
                                    }
                                    
                                    Spacer()
                                    Text(pdf.formattedSize).font(.caption).foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    toggleSelection(pdf)
                                }
                            }
                        }
                    }
                }
                
                Button(action: mergeFiles) {
                    if isMerging {
                        ProgressView().progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Text("Merge \(selectedPDFs.count) Files")
                            .bold()
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(selectedPDFs.count < 2 ? Color.gray : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
                .disabled(selectedPDFs.count < 2 || isMerging || outputName.isEmpty)
                .padding()
            }
            .navigationTitle("Merge Files")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let preselected = preselectedPDFs {
                    selectedPDFs = preselected
                }
                // Auto-detect format if all same
                let selectedFiles = conversionManager.convertedPDFs.filter { selectedPDFs.contains($0.id) }
                if !selectedFiles.isEmpty {
                    let firstExt = selectedFiles.first?.url.pathExtension.lowercased()
                    if selectedFiles.allSatisfy({ $0.url.pathExtension.lowercased() == firstExt }) {
                        if firstExt == "epub" { targetFormat = .epub }
                        else { targetFormat = .pdf }
                    }
                }
            }
        }
    }
    
    private var hasMixedTypes: Bool {
        let selectedFiles = conversionManager.convertedPDFs.filter { selectedPDFs.contains($0.id) }
        guard let first = selectedFiles.first else { return false }
        let firstExt = first.url.pathExtension.lowercased()
        return !selectedFiles.allSatisfy { $0.url.pathExtension.lowercased() == firstExt }
    }
    
    private func toggleSelection(_ pdf: ConvertedPDF) {
        if selectedPDFs.contains(pdf.id) {
            selectedPDFs.remove(pdf.id)
        } else {
            selectedPDFs.insert(pdf.id)
        }
    }
    
    private func mergeFiles() {
        guard !outputName.isEmpty else { return }
        isMerging = true
        
        // Sort files by name (natural order) to ensure chapters merge correctly
        let filesToMerge = conversionManager.convertedPDFs
            .filter { selectedPDFs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        
        Task {
            do {
                let url = try await conversionManager.mergeMixedFiles(files: filesToMerge, outputName: outputName, targetFormat: targetFormat)
                await MainActor.run {
                    conversionManager.addToLibrary(url)
                    isMerging = false
                    dismiss()
                }
            } catch {
                print("Merge failed: \(error)")
                await MainActor.run { isMerging = false }
            }
        }
    }
}

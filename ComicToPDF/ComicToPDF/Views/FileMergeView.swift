import SwiftUI

struct FileMergeView: View {
    enum MergeSortOrder {
        case byName
        case byDate
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var selectedPDFs: Set<UUID> = []

    @State private var outputName: String = "Merged Book"
    @State private var isMerging = false
    @State private var targetFormat: OutputFormat = .pdf
    @State private var sortOrder: MergeSortOrder = .byName
    
    // Explicit list passed if triggered from selection
    var preselectedPDFs: Set<UUID>? = nil
    
    var body: some View {
        NavigationView {
            VStack {
                Form {
                    Section(header: Text("Settings")) {
                        TextField("Output Name", text: $outputName)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.words)
                        
                        Text("File will be saved as: \(outputName).\(targetFormat.rawValue.lowercased())")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Picker("Output Format", selection: $targetFormat) {
                            ForEach(OutputFormat.allCases) { format in
                                Label(format.rawValue, systemImage: format.icon).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                        
                        Picker("Sort Order", selection: $sortOrder) {
                            Text("By Name").tag(MergeSortOrder.byName)
                            Text("By Date Added").tag(MergeSortOrder.byDate)
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
                            ForEach(sortedFiles) { pdf in
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
                
                Section(header: Text("Merge Order Preview")) {
                    if !sortedFiles.filter({ selectedPDFs.contains($0.id) }).isEmpty {
                        ForEach(Array(sortedFiles.filter { selectedPDFs.contains($0.id) }.enumerated()), id: \.element.id) { index, pdf in
                            HStack {
                                Text("\(index + 1).")
                                    .font(.headline)
                                    .foregroundColor(.orange)
                                    .frame(width: 30)
                                VStack(alignment: .leading) {
                                    Text(pdf.name)
                                        .font(.subheadline)
                                    Text("\(pdf.pageCount) pages")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                    } else {
                        Text("No files selected")
                            .foregroundColor(.secondary)
                            .font(.caption)
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
                
                // Auto-detect format and smart naming
                let selectedFiles = conversionManager.convertedPDFs.filter { selectedPDFs.contains($0.id) }
                
                if outputName == "Merged Book" && !selectedFiles.isEmpty {
                    let firstFile = selectedFiles.first!.name
                    let commonPrefix = selectedFiles.reduce(firstFile) { result, pdf in
                        let name = pdf.name
                        var i = 0
                        while i < result.count && i < name.count && result[result.index(result.startIndex, offsetBy: i)] == name[name.index(name.startIndex, offsetBy: i)] {
                            i += 1
                        }
                        return String(result.prefix(i))
                    }
                    
                    let trimmed = commonPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
                        
                    if trimmed.count > 3 {
                        outputName = trimmed
                    }
                }
                
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
    
    private var sortedFiles: [ConvertedPDF] {
        let allFiles = conversionManager.convertedPDFs
        switch sortOrder {
        case .byName:
            return allFiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .byDate:
            return allFiles.sorted { $0.dateAdded > $1.dateAdded }
        }
    }
    
    private func mergeFiles() {
        guard !outputName.isEmpty else { return }
        isMerging = true
        
        // Use sortedFiles filtered by selection
        let filesToMerge = sortedFiles.filter { selectedPDFs.contains($0.id) }
        
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

import SwiftUI

// MARK: - Convert Action Views

// MARK: Rename Before Convert Sheet (for Convert View)
struct RenameSheetView: View {
    let fileURL: URL?
    @Binding var customFileNames: [URL: String]
    @Binding var isPresented: Bool
    
    @State private var newName: String = ""
    
    var originalName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? ""
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Output file name", text: $newName)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: {
                    Text("New Name")
                } footer: {
                    Text("This will be the name of the converted PDF file.")
                }
                
                Section {
                    if let url = fileURL {
                        HStack {
                            Text("Original")
                            Spacer()
                            Text(url.lastPathComponent)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    HStack {
                        Text("Output PDF")
                        Spacer()
                        Text("\(newName.isEmpty ? originalName : newName).pdf")
                            .foregroundColor(.orange)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                } header: {
                    Text("Preview")
                }
            }
            .navigationTitle("Rename Output")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        if let url = fileURL {
                            if !newName.isEmpty && newName != originalName {
                                customFileNames[url] = newName
                            } else {
                                customFileNames.removeValue(forKey: url)
                            }
                        }
                        isPresented = false
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                if let url = fileURL {
                    newName = customFileNames[url] ?? url.deletingPathExtension().lastPathComponent
                }
            }
        }
    }
}

// MARK: Updated File Row with Rename (for Convert View)
struct FileRowViewWithRename: View {
    let url: URL
    let customName: String?
    let onRename: () -> Void
    let onDelete: () -> Void
    
    var displayName: String { customName ?? url.deletingPathExtension().lastPathComponent }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: url.pathExtension.lowercased() == "cbr" ? "doc.zipper.fill" : "doc.zipper")
                .font(.title2).foregroundColor(.orange).frame(width: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).font(.subheadline).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 4) {
                    Text(url.pathExtension.uppercased()).font(.caption2).foregroundColor(.secondary).padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.2).cornerRadius(4))
                    if customName != nil { Text("renamed").font(.caption2).foregroundColor(.blue).padding(.horizontal, 6).padding(.vertical, 2).background(Color.blue.opacity(0.2).cornerRadius(4)) }
                }
            }
            
            Spacer()
            
            Button(action: onRename) { Image(systemName: "pencil.circle.fill").foregroundColor(.blue).font(.title2) }
            Button(action: onDelete) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}

// MARK: - File Merge View
struct FileMergeView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    @State private var selectedIDs: Set<UUID> = []
    @State private var mergedName: String = ""
    
    var body: some View {
        NavigationView {
            VStack {
                TextField("Collection Name (e.g. Omnibus Vol 1)", text: $mergedName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
                
                List(conversionManager.convertedPDFs, id: \.id) { pdf in
                    HStack {
                        Image(systemName: selectedIDs.contains(pdf.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedIDs.contains(pdf.id) ? .blue : .gray)
                        Text(pdf.name)
                        Spacer()
                        Text(pdf.formattedSize).font(.caption).foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedIDs.contains(pdf.id) {
                            selectedIDs.remove(pdf.id)
                        } else {
                            selectedIDs.insert(pdf.id)
                        }
                    }
                }
                
                Button(action: {
                    let selectedFiles = conversionManager.convertedPDFs.filter { selectedIDs.contains($0.id) }
                    Task {
                        await conversionManager.mergePDFs(selectedFiles, outputName: mergedName)
                        dismiss()
                    }
                }) {
                    HStack {
                        if conversionManager.isConverting { ProgressView().padding(.trailing, 5) }
                        Text("Merge \(selectedIDs.count) Files")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(selectedIDs.count < 2 ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(selectedIDs.count < 2 || conversionManager.isConverting)
                .padding()
            }
            .navigationTitle("Merge Files")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Duplicate Finder Components
struct DuplicateDetectionView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var duplicateGroups: [DuplicateGroup] = []
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView("Scanning for duplicates...")
            } else if duplicateGroups.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    Text("No Duplicates Found").font(.title2).bold()
                    Text("Your library is clean!").foregroundColor(.secondary)
                }
            } else {
                duplicateList
            }
        }
        .navigationTitle("Duplicate Finder")
        .task {
            duplicateGroups = await conversionManager.findDuplicates()
            isLoading = false
        }
    }
    
    var duplicateList: some View {
        List {
            ForEach(duplicateGroups) { group in
                Section(header: Text("Identical Files (\(group.files.count))")) {
                    ForEach(group.files) { pdf in
                        DuplicateRow(pdf: pdf) {
                            deletePDF(pdf)
                        }
                    }
                }
            }
        }
    }
    
    func deletePDF(_ pdf: ConvertedPDF) {
        withAnimation {
            conversionManager.removeFromLibrary(pdf)
            // Refresh list if needed
        }
    }
}

struct DuplicateRow: View {
    let pdf: ConvertedPDF
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(pdf.name).font(.headline)
                Text(pdf.formattedSize).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash").foregroundColor(.red)
            }
        }
    }
}

// MARK: - Batch Rename View
struct BatchRenameView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var pattern = "{series} - #{issue}"
    @State private var startNumber = 1
    @State private var selectedFiles: Set<UUID> = []
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Rename Pattern")) {
                    TextField("Pattern (e.g., {series} #{issue})", text: $pattern)
                    Stepper("Start Number: \(startNumber)", value: $startNumber)
                    
                    Text("Available Tags: {series}, {issue}, {title}, {author}")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section(header: Text("Preview")) {
                    if let first = conversionManager.convertedPDFs.first {
                        Text(previewName(for: first))
                            .foregroundColor(.blue)
                    }
                }
                
                Section(header: Text("Select Files")) {
                    List {
                        ForEach(conversionManager.convertedPDFs) { pdf in
                            HStack {
                                Image(systemName: selectedFiles.contains(pdf.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedFiles.contains(pdf.id) ? .blue : .gray)
                                Text(pdf.name)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedFiles.contains(pdf.id) {
                                    selectedFiles.remove(pdf.id)
                                } else {
                                    selectedFiles.insert(pdf.id)
                                }
                            }
                        }
                    }
                }
                
                Button("Rename \(selectedFiles.count) Files") {
                    performRename()
                }
                .disabled(selectedFiles.isEmpty)
            }
            .navigationTitle("Batch Rename")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }
    
    func previewName(for pdf: ConvertedPDF) -> String {
        var name = pattern
        // ✅ Fix: Coalesce optionals to empty strings
        name = name.replacingOccurrences(of: "{series}", with: pdf.metadata.series ?? "Series")
        name = name.replacingOccurrences(of: "{issue}", with: pdf.metadata.issueNumber ?? "\(startNumber)")
        name = name.replacingOccurrences(of: "{title}", with: pdf.metadata.title)
        name = name.replacingOccurrences(of: "{author}", with: pdf.metadata.author ?? "Unknown")
        return name + "." + pdf.url.pathExtension
    }
    
    func performRename() {
        // Implementation stub for now
        dismiss()
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct ImportQueueView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var stagedURLs: [URL] = []
    @State private var showingPicker = false
    @State private var isImporting = false
    
    var body: some View {
        NavigationView {
            ZStack {
                Theme.bg.ignoresSafeArea()
                
                if stagedURLs.isEmpty {
                    VStack(alignment: .center, spacing: 16) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 64))
                            .foregroundColor(Theme.orange)
                            
                        Text("Staging Queue Is Empty")
                            .font(.title2).bold()
                            .foregroundColor(Theme.text)
                            
                        Text("Add comics from different folders into this queue. Once you've selected everything, tap 'Import All' to process them together.")
                            .multilineTextAlignment(.center)
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, 32)
                            
                        Button {
                            showingPicker = true
                        } label: {
                            Label("Add Files", systemImage: "plus")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .frame(maxWidth: 200)
                                .background(Theme.blue)
                                .cornerRadius(12)
                        }
                        .padding(.top, 20)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(stagedURLs, id: \.self) { url in
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundColor(Theme.blue)
                                Text(url.lastPathComponent)
                                    .foregroundColor(Theme.text)
                            }
                            .listRowBackground(Theme.surface)
                        }
                        .onDelete(perform: deleteFiles)
                    }
                    .listStyle(InsetGroupedListStyle())
                    .scrollContentBackground(.hidden)
                }
                
                // Processing Overlay
                if isImporting {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                        Text("Importing \(stagedURLs.count) files...")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                    .padding(32)
                    .background(Theme.surfaceElevated)
                    .cornerRadius(16)
                    .shadow(radius: 10)
                }
            }
            .navigationTitle("Import Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                        .disabled(isImporting)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Import All") {
                        startImport()
                    }
                    .font(.headline)
                    .foregroundColor(Theme.orange)
                    .disabled(stagedURLs.isEmpty || isImporting)
                }
                
                ToolbarItem(placement: .bottomBar) {
                    if !stagedURLs.isEmpty {
                        Button {
                            showingPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Add More Files")
                            }
                            .font(.headline)
                        }
                        .disabled(isImporting)
                    }
                }
            }
            .sheet(isPresented: $showingPicker) {
                DocumentPicker(onDocumentsPicked: { newURLs in
                    DispatchQueue.global(qos: .userInitiated).async {
                        var extractedURLs: [URL] = []
                        let fileManager = FileManager.default
                        let allowedExtensions: Set<String> = ["pdf", "cbz", "zip", "epub"]
                        
                        for url in newURLs {
                            // Request security access to read outside the sandbox
                            let secured = url.startAccessingSecurityScopedResource()
                            
                            var isDirectory: ObjCBool = false
                            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                                // Recursively search the directory
                                if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                                    for case let fileURL as URL in enumerator {
                                        if allowedExtensions.contains(fileURL.pathExtension.lowercased()) {
                                            extractedURLs.append(fileURL)
                                        }
                                    }
                                }
                            } else {
                                // It's a standard single file selection
                                if allowedExtensions.contains(url.pathExtension.lowercased()) {
                                    extractedURLs.append(url)
                                }
                            }
                            
                            if secured {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }
                        
                        DispatchQueue.main.async {
                            // Append extracted URLs while avoiding exact duplicates
                            for url in extractedURLs {
                                if !self.stagedURLs.contains(where: { $0.lastPathComponent == url.lastPathComponent }) {
                                    self.stagedURLs.append(url)
                                }
                            }
                        }
                    }
                })
            }
        }
    }
    
    private func deleteFiles(at offsets: IndexSet) {
        stagedURLs.remove(atOffsets: offsets)
    }
    
    private func startImport() {
        guard !stagedURLs.isEmpty else { return }
        isImporting = true
        
        let urlsToProcess = stagedURLs
        
        Task {
            await conversionManager.importFilesAsSeries(urls: urlsToProcess)
            
            await MainActor.run {
                isImporting = false
                dismiss()
            }
        }
    }
}

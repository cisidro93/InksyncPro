import SwiftUI
import UniformTypeIdentifiers

struct ConvertView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingFilePicker = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var selectedFiles: [URL] = []
    @State private var isConverting = false
    @State private var conversionProgress: Double = 0
    @State private var currentFileName = ""
    
    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: [Color(.systemBackground), Color.orange.opacity(0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        headerCard
                        fileSelectionArea
                        
                        if !selectedFiles.isEmpty {
                            selectedFilesSection
                        }
                        
                        if isConverting {
                            conversionProgressSection
                        }
                        
                        if !selectedFiles.isEmpty && !isConverting {
                            convertButton
                        }
                        
                        Spacer(minLength: 100)
                    }
                    .padding()
                }
            }
            .navigationTitle("Comic to PDF")
            .navigationBarTitleDisplayMode(.large)
            .fullScreenCover(isPresented: $showingFilePicker) {
                DocumentPickerView(selectedFiles: $selectedFiles, isPresented: $showingFilePicker)
                    .ignoresSafeArea()
            }
            .alert("Status", isPresented: $showingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .onReceive(conversionManager.$externalImportURLs) { urls in
                guard !urls.isEmpty else { return }
                
                withAnimation {
                    // Add unique files
                    let existingNames = Set(selectedFiles.map { $0.lastPathComponent })
                    let newFiles = urls.filter { !existingNames.contains($0.lastPathComponent) }
                    selectedFiles.append(contentsOf: newFiles)
                }
                
                // Clear buffer
                conversionManager.externalImportURLs.removeAll()
                
                // Optional: Alert user
                if !urls.isEmpty {
                    alertMessage = "Received \(urls.count) file(s) from external app"
                    showingAlert = true
                }
            }
        }
        .navigationViewStyle(.stack)
    }
    
    // MARK: - Updated Header Card with Bold Type Logo
    
    private var headerCard: some View {
        VStack(spacing: 16) {
            // Bold Type Logo
            AppLogo(size: 80)
                .shadow(color: .orange.opacity(0.3), radius: 10, y: 5)
            
            Text("CBZ/CBR to PDF Converter")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Convert your comic archives to PDF format for Kindle reading")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 30)
        .padding(.horizontal)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
    }
    
    private var fileSelectionArea: some View {
        Button(action: { showingFilePicker = true }) {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.2))
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                }
                
                Text("Select CBZ/CBR Files")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text("Tap to browse your files")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [10]))
                    .foregroundColor(.orange.opacity(0.5))
            )
        }
    }
    
    private var selectedFilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Selected Files")
                    .font(.headline)
                
                Spacer()
                
                Button("Clear All") {
                    withAnimation {
                        selectedFiles.removeAll()
                    }
                }
                .font(.caption)
                .foregroundColor(.red)
            }
            
            ForEach(selectedFiles, id: \.absoluteString) { url in
                FileRowView(url: url) {
                    withAnimation {
                        selectedFiles.removeAll { $0 == url }
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
    }
    
    private var conversionProgressSection: some View {
        VStack(spacing: 16) {
            ProgressView(value: conversionProgress)
                .progressViewStyle(LinearProgressViewStyle(tint: .orange))
                .scaleEffect(y: 2)
            
            Text("Converting: \(currentFileName)")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("\(Int(conversionProgress * 100))%")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.orange)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
    }
    
    private var convertButton: some View {
        Button(action: startConversion) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Convert \(selectedFiles.count) File\(selectedFiles.count > 1 ? "s" : "")")
                    .fontWeight(.semibold)
            }
            .foregroundColor(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [.orange, .red],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(16)
            .shadow(color: .orange.opacity(0.4), radius: 10, y: 5)
        }
    }
    
    private func startConversion() {
        isConverting = true
        conversionProgress = 0
        
        Task {
            do {
                for (index, fileURL) in selectedFiles.enumerated() {
                    let accessing = fileURL.startAccessingSecurityScopedResource()
                    defer {
                        if accessing {
                            fileURL.stopAccessingSecurityScopedResource()
                        }
                    }
                    
                    await MainActor.run {
                        currentFileName = fileURL.lastPathComponent
                    }
                    
                    let outputURL = try await conversionManager.convertToPDF(
                        from: fileURL,
                        progressHandler: { progress in
                            Task { @MainActor in
                                let fileProgress = Double(index) / Double(selectedFiles.count)
                                let itemProgress = progress / Double(selectedFiles.count)
                                conversionProgress = fileProgress + itemProgress
                            }
                        }
                    )
                    
                    await MainActor.run {
                        conversionManager.addToLibrary(outputURL)
                    }
                }
                
                await MainActor.run {
                    isConverting = false
                    conversionProgress = 1.0
                    selectedFiles.removeAll()
                    alertMessage = "All files converted successfully! Check the Library tab."
                    showingAlert = true
                }
                
            } catch {
                await MainActor.run {
                    isConverting = false
                    alertMessage = "Conversion failed: \(error.localizedDescription)"
                    showingAlert = true
                }
            }
        }
    }
}

// MARK: - Document Picker

struct DocumentPickerView: UIViewControllerRepresentable {
    @Binding var selectedFiles: [URL]
    @Binding var isPresented: Bool
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerView
        
        init(parent: DocumentPickerView) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            let validExtensions = ["cbz", "cbr", "zip", "rar"]
            
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if validExtensions.contains(ext) {
                    if !parent.selectedFiles.contains(where: { $0.lastPathComponent == url.lastPathComponent }) {
                        parent.selectedFiles.append(url)
                    }
                }
            }
            
            parent.isPresented = false
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
    }
}

// MARK: - File Row View

struct FileRowView: View {
    let url: URL
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconForExtension(url.pathExtension))
                .font(.title2)
                .foregroundColor(.orange)
                .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                Text(url.pathExtension.uppercased())
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(4)
            }
            
            Spacer()
            
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }
    
    private func iconForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "cbz", "zip":
            return "doc.zipper"
        case "cbr", "rar":
            return "doc.zipper.fill"
        default:
            return "doc"
        }
    }
}

#Preview {
    ConvertView()
        .environmentObject(ConversionManager())
}

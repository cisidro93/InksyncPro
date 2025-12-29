import SwiftUI
import UniformTypeIdentifiers

// MARK: - Compression Settings Model

struct CompressionSettings {
    var quality: CompressionQuality = .high
    var customScale: Double = 1.0  // 1.0 = 100%, 0.5 = 50%
    var jpegQuality: Double = 0.85 // 0.0 to 1.0
    
    enum CompressionQuality: String, CaseIterable {
        case original = "Original"
        case high = "High Quality"
        case balanced = "Balanced"
        case compact = "Compact"
        case custom = "Custom"
        
        var description: String {
            switch self {
            case .original: return "No compression - largest file size"
            case .high: return "Minimal compression - best quality"
            case .balanced: return "Good balance of size and quality"
            case .compact: return "Smaller files - good for email"
            case .custom: return "Adjust settings manually"
            }
        }
        
        var icon: String {
            switch self {
            case .original: return "doc.fill"
            case .high: return "star.fill"
            case .balanced: return "scale.3d"
            case .compact: return "arrow.down.doc.fill"
            case .custom: return "slider.horizontal.3"
            }
        }
        
        var color: Color {
            switch self {
            case .original: return .blue
            case .high: return .green
            case .balanced: return .orange
            case .compact: return .purple
            case .custom: return .pink
            }
        }
        
        // Returns (scale, jpegQuality)
        var presetValues: (Double, Double) {
            switch self {
            case .original: return (1.0, 1.0)
            case .high: return (1.0, 0.9)
            case .balanced: return (0.85, 0.8)
            case .compact: return (0.7, 0.7)
            case .custom: return (1.0, 0.85)
            }
        }
        
        var estimatedSizeReduction: String {
            switch self {
            case .original: return "0%"
            case .high: return "~20%"
            case .balanced: return "~40%"
            case .compact: return "~60%"
            case .custom: return "Variable"
            }
        }
    }
}

// MARK: - Convert View with Compression

struct ConvertView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingFilePicker = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var selectedFiles: [URL] = []
    @State private var isConverting = false
    @State private var conversionProgress: Double = 0
    @State private var currentFileName = ""
    
    // Compression settings
    @State private var compressionSettings = CompressionSettings()
    @State private var showCompressionOptions = false
    
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
                            compressionSection
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
    
    // MARK: - Header Card with Logo
    
    private var headerCard: some View {
        VStack(spacing: 16) {
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
    
    // MARK: - File Selection Area
    
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
    
    // MARK: - Selected Files Section
    
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
    
    // MARK: - Compression Section
    
    private var compressionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with toggle
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(.orange)
                
                Text("Compression Settings")
                    .font(.headline)
                
                Spacer()
                
                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        showCompressionOptions.toggle()
                    }
                }) {
                    Image(systemName: showCompressionOptions ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                        .font(.title2)
                        .foregroundColor(.orange)
                }
            }
            
            // Current selection summary
            HStack {
                Image(systemName: compressionSettings.quality.icon)
                    .foregroundColor(compressionSettings.quality.color)
                
                Text(compressionSettings.quality.rawValue)
                    .fontWeight(.medium)
                
                Spacer()
                
                Text("~\(estimatedOutputSize) per file")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(compressionSettings.quality.color.opacity(0.1))
            )
            
            if showCompressionOptions {
                // Quality Presets
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quality Preset")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    ForEach(CompressionSettings.CompressionQuality.allCases, id: \.self) { quality in
                        CompressionPresetButton(
                            quality: quality,
                            isSelected: compressionSettings.quality == quality,
                            action: {
                                withAnimation {
                                    compressionSettings.quality = quality
                                    let values = quality.presetValues
                                    compressionSettings.customScale = values.0
                                    compressionSettings.jpegQuality = values.1
                                }
                            }
                        )
                    }
                }
                
                // Custom sliders (only show when Custom is selected)
                if compressionSettings.quality == .custom {
                    VStack(spacing: 20) {
                        Divider()
                        
                        // Resolution Scale Slider
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Resolution Scale")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int(compressionSettings.customScale * 100))%")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.orange)
                            }
                            
                            Slider(value: $compressionSettings.customScale, in: 0.3...1.0, step: 0.05)
                                .tint(.orange)
                            
                            HStack {
                                Text("Smaller")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("Original")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // JPEG Quality Slider
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Image Quality")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int(compressionSettings.jpegQuality * 100))%")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.orange)
                            }
                            
                            Slider(value: $compressionSettings.jpegQuality, in: 0.5...1.0, step: 0.05)
                                .tint(.orange)
                            
                            HStack {
                                Text("Compressed")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("Best Quality")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                
                // Info box
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    
                    Text("Higher compression reduces file size but may affect image clarity. 'Balanced' is recommended for most comics.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.1))
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
    }
    
    private var estimatedOutputSize: String {
        // Rough estimation based on compression settings
        let baseSize = 50.0 // Assume 50MB average comic
        let scale = compressionSettings.quality == .custom ? compressionSettings.customScale : compressionSettings.quality.presetValues.0
        let jpegQuality = compressionSettings.quality == .custom ? compressionSettings.jpegQuality : compressionSettings.quality.presetValues.1
        
        let estimatedSize = baseSize * scale * scale * jpegQuality
        
        if estimatedSize < 1 {
            return "\(Int(estimatedSize * 1024))KB"
        } else {
            return "\(Int(estimatedSize))MB"
        }
    }
    
    // MARK: - Progress Section
    
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
    
    // MARK: - Convert Button
    
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
    
    // MARK: - Conversion Logic
    
    private func startConversion() {
        isConverting = true
        conversionProgress = 0
        
        // Get compression values
        let scale: Double
        let jpegQuality: Double
        
        if compressionSettings.quality == .custom {
            scale = compressionSettings.customScale
            jpegQuality = compressionSettings.jpegQuality
        } else {
            let values = compressionSettings.quality.presetValues
            scale = values.0
            jpegQuality = values.1
        }
        
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
                        scale: scale,
                        jpegQuality: jpegQuality,
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

// MARK: - Compression Preset Button

struct CompressionPresetButton: View {
    let quality: CompressionSettings.CompressionQuality
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    Circle()
                        .fill(quality.color.opacity(isSelected ? 0.2 : 0.1))
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: quality.icon)
                        .foregroundColor(quality.color)
                }
                
                // Text
                VStack(alignment: .leading, spacing: 2) {
                    Text(quality.rawValue)
                        .font(.subheadline)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundColor(.primary)
                    
                    Text(quality.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Size reduction badge
                Text(quality.estimatedSizeReduction)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(quality.color.opacity(0.15))
                    .foregroundColor(quality.color)
                    .cornerRadius(6)
                
                // Checkmark
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? quality.color.opacity(0.1) : Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isSelected ? quality.color : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
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

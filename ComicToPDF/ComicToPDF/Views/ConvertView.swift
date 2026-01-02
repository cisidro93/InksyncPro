// ============================================================================
// ENHANCED CONVERTVIEW WITH IMPROVED UI
// ============================================================================

import SwiftUI

struct ConvertView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingFilePicker = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var selectedFiles: [URL] = []
    @State private var isConverting = false
    @State private var conversionProgress: Double = 0
    @State private var currentFileName = ""
    @State private var showCompressionOptions = false
    @State private var showEnhancementOptions = false
    @State private var showDeviceOptions = false
    @State private var settings = ConversionSettings()
    @State private var showingRenameSheet = false
    @State private var renameFileURL: URL? = nil
    @State private var customFileNames: [URL: String] = [:]
    @State private var autoSplitEnabled = true
    @State private var showingSuccessAnimation = false
    @State private var hasAppeared = false
    
    // ENHANCED UI STATE
    @State private var currentStage = ""
    @State private var detailedStatus = ""
    @State private var currentFileIndex = 0
    @State private var totalFiles = 0
    @State private var inputFileSize: Int64 = 0
    @State private var outputFileSize: Int64 = 0
    @State private var conversionStartTime: Date?
    @State private var showingDetailedProgress = false
    @State private var isSplitting = false
    @State private var splitPartCount = 0
    
    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: [Color(.systemBackground), Color.orange.opacity(0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                ).ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        headerCard
                        fileSelectionArea
                        
                        if !selectedFiles.isEmpty {
                            selectedFilesSection
                            mangaModeToggle
                            autoSplitSection
                            outputFormatSection
                            
                            if settings.outputFormat != .pdf {
                                epubSettingsSection
                            }
                            
                            compressionSection
                            imageEnhancementSection
                            deviceOptimizationSection
                        }
                        
                        // ENHANCED PROGRESS SECTION
                        if isConverting {
                            enhancedProgressSection
                        }
                        
                        // Action buttons
                        VStack(spacing: 12) {
                            if !selectedFiles.isEmpty {
                                Button(action: startConversion) {
                                    HStack {
                                        if isConverting {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        } else {
                                            Image(systemName: "arrow.right.circle.fill")
                                        }
                                        Text(isConverting ? "Converting..." : "Convert Now")
                                            .fontWeight(.bold)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(isConverting ? Color.gray : Color.orange)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                                }
                                .disabled(isConverting)
                            }
                            
                            Button(action: { showingFilePicker = true }) {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Select Files")
                                }
                                .font(.headline)
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        Spacer(minLength: 60)
                    }
                    .padding()
                }
            }
            .navigationTitle("Comic Converter")
            .navigationBarTitleDisplayMode(.large)
            .fullScreenCover(isPresented: $showingFilePicker) {
                EnhancedDocumentPicker(
                    selectedFiles: $selectedFiles,
                    isPresented: $showingFilePicker
                )
                .ignoresSafeArea()
            }
            .alert("Status", isPresented: $showingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .onAppear {
                if !hasAppeared {
                    settings = conversionManager.conversionSettings
                    hasAppeared = true
                }
            }
            .sheet(isPresented: $showingRenameSheet) {
                RenameSheetView(
                    fileURL: renameFileURL,
                    customFileNames: $customFileNames,
                    isPresented: $showingRenameSheet
                )
            }
            .overlay(Group {
                if showingSuccessAnimation {
                    enhancedSuccessView
                }
            })
        }
        .navigationViewStyle(.stack)
    }
    
    // MARK: - Enhanced Progress Section
    
    private var enhancedProgressSection: some View {
        VStack(spacing: 20) {
            // File counter
            HStack {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundColor(.orange)
                Text("File \(currentFileIndex + 1) of \(totalFiles)")
                    .font(.headline)
                Spacer()
                if let startTime = conversionStartTime {
                    elapsedTimeView(startTime: startTime)
                }
            }
            
            // Main progress bar
            VStack(spacing: 8) {
                ProgressView(value: conversionProgress)
                    .progressViewStyle(LinearProgressViewStyle(tint: .orange))
                    .scaleEffect(y: 3)
                
                HStack {
                    Text("\(Int(conversionProgress * 100))%")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                    Spacer()
                    if isSplitting {
                        HStack(spacing: 4) {
                            Image(systemName: "scissors")
                            Text("Splitting...")
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                    }
                }
            }
            
            // Current file and stage
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .foregroundColor(.orange)
                    Text(currentFileName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                
                HStack {
                    Image(systemName: stageIcon)
                        .foregroundColor(.secondary)
                    Text(currentStage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if !detailedStatus.isEmpty {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text(detailedStatus)
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                
                // File size info
                if inputFileSize > 0 {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Input")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(formatFileSize(inputFileSize))
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "arrow.right")
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        if outputFileSize > 0 {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Output")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(formatFileSize(outputFileSize))
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(compressionColor)
                            }
                        } else {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Output")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("Processing...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                // Splitting info
                if splitPartCount > 0 {
                    HStack {
                        Image(systemName: "scissors")
                            .foregroundColor(.blue)
                        Text("Split into \(splitPartCount) parts")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .orange.opacity(0.2), radius: 10, y: 5)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }
    
    private func elapsedTimeView(startTime: Date) -> some View {
        let elapsed = Date().timeIntervalSince(startTime)
        return HStack(spacing: 4) {
            Image(systemName: "clock.fill")
                .font(.caption)
            Text(formatElapsedTime(elapsed))
                .font(.caption)
                .monospacedDigit()
        }
        .foregroundColor(.secondary)
    }
    
    private var stageIcon: String {
        switch currentStage {
        case let s where s.contains("Extracting"):
            return "arrow.down.doc.fill"
        case let s where s.contains("Processing"):
            return "gearshape.fill"
        case let s where s.contains("Building"):
            return "hammer.fill"
        case let s where s.contains("Splitting"):
            return "scissors"
        case let s where s.contains("Complete"):
            return "checkmark.circle.fill"
        default:
            return "doc.fill"
        }
    }
    
    private var compressionColor: Color {
        guard inputFileSize > 0 && outputFileSize > 0 else { return .primary }
        let ratio = Double(outputFileSize) / Double(inputFileSize)
        if ratio < 0.5 { return .green }
        if ratio < 0.8 { return .blue }
        if ratio < 1.0 { return .orange }
        return .red
    }
    
    // MARK: - Enhanced Success View
    
    private var enhancedSuccessView: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Success animation
                ZStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 100, height: 100)
                    
                    Image(systemName: "checkmark")
                        .font(.system(size: 50, weight: .bold))
                        .foregroundColor(.white)
                }
                .scaleEffect(showingSuccessAnimation ? 1.0 : 0.5)
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: showingSuccessAnimation)
                
                VStack(spacing: 8) {
                    Text("Conversion Complete!")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    if totalFiles > 1 {
                        Text("\(totalFiles) files converted")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    if outputFileSize > 0 {
                        HStack(spacing: 4) {
                            Text(formatFileSize(inputFileSize))
                                .foregroundColor(.secondary)
                            Image(systemName: "arrow.right")
                                .foregroundColor(.secondary)
                            Text(formatFileSize(outputFileSize))
                                .fontWeight(.medium)
                                .foregroundColor(.green)
                        }
                        .font(.caption)
                    }
                    
                    if splitPartCount > 0 {
                        Text("Split into \(splitPartCount) parts")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                
                Button("Done") {
                    withAnimation {
                        showingSuccessAnimation = false
                        resetConversionState()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
            )
            .padding()
        }
    }
    
    // MARK: - Existing UI Components (keep these as is)
    
    private var headerCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            Text("Comic Converter")
                .font(.title2)
                .fontWeight(.bold)
            Text("Convert comic archives to PDF or EPUB for e-readers")
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
                Text("Select Files")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("CBZ, CBR, CB7, EPUB, PDF")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2, dash: [10])
                    )
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
                        customFileNames.removeAll()
                    }
                }
                .font(.caption)
                .foregroundColor(.red)
            }
            
            ForEach(selectedFiles, id: \.self) { fileURL in
                selectedFileRow(fileURL: fileURL)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
    }
    
    private func selectedFileRow(fileURL: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: fileIcon(for: fileURL))
                .foregroundColor(.orange)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(customFileNames[fileURL] ?? fileURL.lastPathComponent)
                    .font(.subheadline)
                    .lineLimit(1)
                
                if let fileSize = getFileSize(fileURL) {
                    Text(formatFileSize(fileSize))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Menu {
                Button {
                    renameFileURL = fileURL
                    showingRenameSheet = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                
                Button(role: .destructive) {
                    withAnimation {
                        selectedFiles.removeAll { $0 == fileURL }
                        customFileNames.removeValue(forKey: fileURL)
                    }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemBackground))
        )
    }
    
    // MARK: - Placeholder sections (keep your existing implementations)
    
    private var mangaModeToggle: some View {
        // Keep your existing implementation
        EmptyView()
    }
    
    private var autoSplitSection: some View {
        // Keep your existing implementation
        EmptyView()
    }
    
    private var outputFormatSection: some View {
        // Keep your existing implementation
        EmptyView()
    }
    
    private var epubSettingsSection: some View {
        // Keep your existing implementation
        EmptyView()
    }
    
    private var compressionSection: some View {
        // Keep your existing implementation
        EmptyView()
    }
    
    private var imageEnhancementSection: some View {
        // Keep your existing implementation
        EmptyView()
    }
    
    private var deviceOptimizationSection: some View {
        // Keep your existing implementation
        EmptyView()
    }
    
    // MARK: - Conversion Logic with Enhanced Progress
    
    private func startConversion() {
        isConverting = true
        conversionProgress = 0
        conversionStartTime = Date()
        totalFiles = selectedFiles.count
        currentFileIndex = 0
        splitPartCount = 0
        
        conversionManager.conversionSettings = settings
        conversionManager.saveSettings()
        
        Task {
            do {
                for (index, fileURL) in selectedFiles.enumerated() {
                    currentFileIndex = index
                    
                    let accessing = fileURL.startAccessingSecurityScopedResource()
                    defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
                    
                    await MainActor.run {
                        currentFileName = fileURL.lastPathComponent
                        currentStage = "Preparing..."
                        detailedStatus = ""
                        inputFileSize = getFileSize(fileURL) ?? 0
                        outputFileSize = 0
                    }
                    
                    let urls = try await conversionManager.convertToFormat(
                        settings.outputFormat,
                        from: fileURL,
                        settings: settings,
                        progressHandler: { progress in
                            Task { @MainActor in
                                // Update stage based on progress
                                if progress < 0.2 {
                                    currentStage = "Extracting archive..."
                                } else if progress < 0.8 {
                                    currentStage = "Processing images..."
                                    if inputFileSize > 200_000_000 {
                                        detailedStatus = "Large file detected - using memory-safe processing"
                                    }
                                } else if progress < 0.95 {
                                    currentStage = "Building output file..."
                                } else {
                                    currentStage = "Finalizing..."
                                }
                                
                                let fileProgress = Double(index) / Double(selectedFiles.count)
                                let itemProgress = progress / Double(selectedFiles.count)
                                conversionProgress = fileProgress + itemProgress
                            }
                        }
                    )
                    
                    await MainActor.run {
                        if urls.count > 1 {
                            currentStage = "Splitting into parts..."
                            isSplitting = true
                            splitPartCount = urls.count
                        } else {
                            currentStage = "Complete!"
                        }
                        
                        // Calculate output size
                        outputFileSize = urls.reduce(0) { total, url in
                            total + (getFileSize(url) ?? 0)
                        }
                        
                        for url in urls {
                            conversionManager.addToLibrary(url)
                        }
                    }
                }
                
                await MainActor.run {
                    conversionProgress = 1.0
                    currentStage = "All files converted!"
                    
                    // Show success animation
                    withAnimation {
                        showingSuccessAnimation = true
                    }
                    
                    // Auto-dismiss after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation {
                            showingSuccessAnimation = false
                            resetConversionState()
                        }
                    }
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
    
    private func resetConversionState() {
        isConverting = false
        conversionProgress = 0
        currentFileName = ""
        currentStage = ""
        detailedStatus = ""
        currentFileIndex = 0
        totalFiles = 0
        inputFileSize = 0
        outputFileSize = 0
        conversionStartTime = nil
        isSplitting = false
        splitPartCount = 0
        selectedFiles.removeAll()
        customFileNames.removeAll()
    }
    
    // MARK: - Helper Functions
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatElapsedTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }
    
    private func getFileSize(_ url: URL) -> Int64? {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        
        return try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
    }
    
    private func fileIcon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "cbz", "cbr", "cb7": return "book.closed.fill"
        case "epub": return "book.fill"
        case "pdf": return "doc.fill"
        default: return "doc"
        }
    }
}

// MARK: - Supporting Views

struct EnhancedDocumentPicker: UIViewControllerRepresentable {
    @Binding var selectedFiles: [URL]
    @Binding var isPresented: Bool
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item],
            asCopy: true
        )
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: EnhancedDocumentPicker
        
        init(_ parent: EnhancedDocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // Validation and update logic
            let validExtensions = ["cbz", "cbr", "zip", "rar", "pdf", "epub", "cb7"]
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if validExtensions.contains(ext) {
                    parent.selectedFiles.append(url)
                }
            }
            parent.isPresented = false
        }
    }
}

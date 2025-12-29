import SwiftUI
import MessageUI

struct LibraryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    
    // Selection state
    @State private var isSelectionMode = false
    @State private var selectedPDFs: Set<UUID> = []
    
    // Single item actions
    @State private var selectedPDF: ConvertedPDF?
    @State private var showingActionSheet = false
    @State private var showingShareSheet = false
    @State private var showingMailComposer = false
    @State private var showingSplitOptions = false
    @State private var showingDeleteAlert = false
    @State private var showingLargeFileOptions = false
    @State private var showingKindleInstructions = false
    @State private var pdfToDelete: ConvertedPDF?
    
    // Batch actions
    @State private var showingBatchMailComposer = false
    @State private var showingBatchShareSheet = false
    @State private var showingBatchDeleteAlert = false
    @State private var showingBatchSizeWarning = false
    @State private var batchTotalSize: Int64 = 0
    
    // Split options
    @State private var splitSize: Int = 25
    @State private var isSplitting = false
    @State private var splitProgress: Double = 0
    
    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: [Color(.systemBackground), Color.blue.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                if conversionManager.convertedPDFs.isEmpty {
                    emptyStateView
                } else {
                    VStack(spacing: 0) {
                        if isSelectionMode {
                            batchActionBar
                        }
                        pdfListView
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !conversionManager.convertedPDFs.isEmpty {
                        Button(isSelectionMode ? "Cancel" : "Select") {
                            withAnimation {
                                isSelectionMode.toggle()
                                if !isSelectionMode {
                                    selectedPDFs.removeAll()
                                }
                            }
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSelectionMode && !conversionManager.convertedPDFs.isEmpty {
                        Button(selectedPDFs.count == conversionManager.convertedPDFs.count ? "Deselect All" : "Select All") {
                            withAnimation {
                                if selectedPDFs.count == conversionManager.convertedPDFs.count {
                                    selectedPDFs.removeAll()
                                } else {
                                    selectedPDFs = Set(conversionManager.convertedPDFs.map { $0.id })
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        
        // MARK: - Single Item Sheets
        .sheet(isPresented: $showingShareSheet) {
            if let pdf = selectedPDF {
                ShareSheet(items: [pdf.url])
            }
        }
        .sheet(isPresented: $showingMailComposer) {
            if let pdf = selectedPDF {
                KindleMailComposer(
                    pdfURLs: [pdf.url],
                    kindleEmail: conversionManager.kindleEmail
                )
            }
        }
        .sheet(isPresented: $showingSplitOptions) {
            if let pdf = selectedPDF {
                SplitOptionsSheet(
                    pdf: pdf,
                    splitSize: $splitSize,
                    isSplitting: $isSplitting,
                    progress: $splitProgress,
                    onSplit: { performSplit(pdf: pdf) }
                )
            }
        }
        .sheet(isPresented: $showingKindleInstructions) {
            if let pdf = selectedPDF {
                KindleWebInstructionsView(pdf: pdf)
            }
        }
        
        // MARK: - Batch Sheets
        .sheet(isPresented: $showingBatchMailComposer) {
            let urls = getSelectedPDFURLs()
            KindleMailComposer(
                pdfURLs: urls,
                kindleEmail: conversionManager.kindleEmail
            )
        }
        .sheet(isPresented: $showingBatchShareSheet) {
            let urls = getSelectedPDFURLs()
            ShareSheet(items: urls)
        }
        
        // MARK: - Alerts
        .alert("Delete PDF?", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let pdf = pdfToDelete {
                    conversionManager.removeFromLibrary(pdf)
                }
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .alert("Delete \(selectedPDFs.count) PDFs?", isPresented: $showingBatchDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All", role: .destructive) {
                deleteSelectedPDFs()
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .alert("Files Too Large for Email", isPresented: $showingBatchSizeWarning) {
            Button("Share to Kindle App Instead") {
                showingBatchShareSheet = true
            }
            Button("Send Anyway (May Fail)") {
                showingBatchMailComposer = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Selected files total \(formatBytes(batchTotalSize)), which exceeds the 50MB email limit. Consider using the Kindle app instead.")
        }
        
        // Single item dialogs
        .confirmationDialog("PDF Options", isPresented: $showingActionSheet, titleVisibility: .visible) {
            Button("Send to Kindle") { sendSingleToKindle() }
            Button("Share") { showingShareSheet = true }
            Button("Split into Parts") { showingSplitOptions = true }
            Button("Delete", role: .destructive) {
                pdfToDelete = selectedPDF
                showingDeleteAlert = true
            }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Send to Kindle Options", isPresented: $showingLargeFileOptions, titleVisibility: .visible) {
            if let pdf = selectedPDF {
                Button("Share to Kindle App") {
                    shareToKindleApp(urls: [pdf.url])
                }
                Button("Use Send to Kindle Website") {
                    showingKindleInstructions = true
                }
                Button("Split into Smaller Parts") {
                    showingSplitOptions = true
                }
                Button("Cancel", role: .cancel) { }
            }
        } message: {
            if let pdf = selectedPDF {
                Text("This file (\(pdf.formattedSize)) is too large for email. Choose an alternative method.")
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray")
                .font(.system(size: 60))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No Converted PDFs")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Convert some CBZ/CBR files to see them here")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
    
    // MARK: - Batch Action Bar
    
    private var batchActionBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                // Selection count
                Text("\(selectedPDFs.count) selected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // Batch Send to Kindle
                Button(action: batchSendToKindle) {
                    VStack(spacing: 4) {
                        Image(systemName: "paperplane.fill")
                            .font(.title3)
                        Text("Kindle")
                            .font(.caption2)
                    }
                    .foregroundColor(selectedPDFs.isEmpty ? .gray : .orange)
                }
                .disabled(selectedPDFs.isEmpty)
                
                // Batch Share
                Button(action: { showingBatchShareSheet = true }) {
                    VStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                        Text("Share")
                            .font(.caption2)
                    }
                    .foregroundColor(selectedPDFs.isEmpty ? .gray : .blue)
                }
                .disabled(selectedPDFs.isEmpty)
                
                // Batch Delete
                Button(action: { showingBatchDeleteAlert = true }) {
                    VStack(spacing: 4) {
                        Image(systemName: "trash.fill")
                            .font(.title3)
                        Text("Delete")
                            .font(.caption2)
                    }
                    .foregroundColor(selectedPDFs.isEmpty ? .gray : .red)
                }
                .disabled(selectedPDFs.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            
            // Size indicator
            if !selectedPDFs.isEmpty {
                HStack {
                    let totalSize = calculateSelectedSize()
                    let sizeColor: Color = totalSize > 50_000_000 ? .red : (totalSize > 25_000_000 ? .orange : .green)
                    
                    Image(systemName: totalSize > 50_000_000 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(sizeColor)
                    
                    Text("Total size: \(formatBytes(totalSize))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if totalSize > 50_000_000 {
                        Text("(exceeds 50MB email limit)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemBackground))
            }
        }
    }
    
    // MARK: - PDF List
    
    private var pdfListView: some View {
        List {
            ForEach(conversionManager.convertedPDFs) { pdf in
                HStack(spacing: 12) {
                    // Selection checkbox (in selection mode)
                    if isSelectionMode {
                        Button(action: { toggleSelection(pdf) }) {
                            Image(systemName: selectedPDFs.contains(pdf.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundColor(selectedPDFs.contains(pdf.id) ? .orange : .gray)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    // PDF Row
                    PDFRowView(pdf: pdf)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isSelectionMode {
                                toggleSelection(pdf)
                            } else {
                                selectedPDF = pdf
                                showingActionSheet = true
                            }
                        }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        pdfToDelete = pdf
                        showingDeleteAlert = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        selectedPDF = pdf
                        sendSingleToKindle()
                    } label: {
                        Label("Kindle", systemImage: "paperplane.fill")
                    }
                    .tint(.orange)
                }
            }
            .onDelete(perform: deletePDFs)
        }
        .listStyle(.insetGrouped)
    }
    
    // MARK: - Helper Functions
    
    private func toggleSelection(_ pdf: ConvertedPDF) {
        withAnimation {
            if selectedPDFs.contains(pdf.id) {
                selectedPDFs.remove(pdf.id)
            } else {
                selectedPDFs.insert(pdf.id)
            }
        }
    }
    
    private func getSelectedPDFURLs() -> [URL] {
        return conversionManager.convertedPDFs
            .filter { selectedPDFs.contains($0.id) }
            .map { $0.url }
    }
    
    private func getSelectedPDFObjects() -> [ConvertedPDF] {
        return conversionManager.convertedPDFs
            .filter { selectedPDFs.contains($0.id) }
    }
    
    private func calculateSelectedSize() -> Int64 {
        return getSelectedPDFObjects().reduce(0) { $0 + $1.fileSize }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    // MARK: - Batch Actions
    
    private func batchSendToKindle() {
        let totalSize = calculateSelectedSize()
        batchTotalSize = totalSize
        
        if totalSize > 50_000_000 {
            // Over 50MB - show warning
            showingBatchSizeWarning = true
        } else {
            // Under 50MB - send via email
            if MFMailComposeViewController.canSendMail() {
                showingBatchMailComposer = true
            } else {
                // No email - use share sheet
                showingBatchShareSheet = true
            }
        }
    }
    
    private func deleteSelectedPDFs() {
        for pdf in getSelectedPDFObjects() {
            conversionManager.removeFromLibrary(pdf)
        }
        selectedPDFs.removeAll()
        isSelectionMode = false
    }
    
    private func shareToKindleApp(urls: [URL]) {
        let activityVC = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = rootViewController.view
                popover.sourceRect = CGRect(x: rootViewController.view.bounds.midX,
                                           y: rootViewController.view.bounds.midY,
                                           width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            
            rootViewController.present(activityVC, animated: true)
        }
    }
    
    // MARK: - Single Item Actions
    
    private func sendSingleToKindle() {
        guard let pdf = selectedPDF else { return }
        
        let fileSizeMB = Double(pdf.fileSize) / (1024 * 1024)
        
        if fileSizeMB <= 50 {
            if MFMailComposeViewController.canSendMail() {
                showingMailComposer = true
            } else {
                showingLargeFileOptions = true
            }
        } else {
            showingLargeFileOptions = true
        }
    }
    
    private func performSplit(pdf: ConvertedPDF) {
        Task {
            do {
                isSplitting = true
                let parts = try await conversionManager.splitPDF(
                    at: pdf.url,
                    maxSizeMB: splitSize,
                    progressHandler: { progress in
                        Task { @MainActor in
                            splitProgress = progress
                        }
                    }
                )
                
                await MainActor.run {
                    isSplitting = false
                    showingSplitOptions = false
                    
                    for partURL in parts {
                        conversionManager.addToLibrary(partURL)
                    }
                }
            } catch {
                await MainActor.run {
                    isSplitting = false
                }
            }
        }
    }
    
    private func deletePDFs(at offsets: IndexSet) {
        for index in offsets {
            conversionManager.removeFromLibrary(conversionManager.convertedPDFs[index])
        }
    }
}

// MARK: - PDF Row View

struct PDFRowView: View {
    let pdf: ConvertedPDF
    
    private var fileSizeMB: Double {
        Double(pdf.fileSize) / (1024 * 1024)
    }
    
    private var sizeColor: Color {
        if fileSizeMB <= 50 { return .green }
        else if fileSizeMB <= 200 { return .orange }
        else { return .red }
    }
    
    var body: some View {
        HStack(spacing: 16) {
            // Thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 50, height: 65)
                
                Image(systemName: "doc.fill")
                    .font(.title2)
                    .foregroundColor(.red)
            }
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(pdf.name)
                    .font(.headline)
                    .lineLimit(2)
                
                HStack(spacing: 8) {
                    Label(pdf.formattedSize, systemImage: "doc")
                        .font(.caption)
                        .foregroundColor(sizeColor)
                    
                    Label("\(pdf.pageCount) pages", systemImage: "book.pages")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text(pdf.dateAdded.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Kindle Mail Composer (Updated for multiple files)

struct KindleMailComposer: UIViewControllerRepresentable {
    let pdfURLs: [URL]
    let kindleEmail: String
    
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients([kindleEmail])
        composer.setSubject("Convert")
        
        let fileCount = pdfURLs.count
        let message = fileCount == 1 
            ? "Sent from Comic to PDF Converter"
            : "Batch send: \(fileCount) files from Comic to PDF Converter"
        composer.setMessageBody(message, isHTML: false)
        
        // Attach all PDFs
        for url in pdfURLs {
            if let pdfData = try? Data(contentsOf: url) {
                composer.addAttachmentData(pdfData, mimeType: "application/pdf", fileName: url.lastPathComponent)
            }
        }
        
        return composer
    }
    
    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }
    
    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: DismissAction
        
        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }
        
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            dismiss()
        }
    }
}

// MARK: - Split Options Sheet

struct SplitOptionsSheet: View {
    let pdf: ConvertedPDF
    @Binding var splitSize: Int
    @Binding var isSplitting: Bool
    @Binding var progress: Double
    let onSplit: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // File info
                VStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.red)
                    
                    Text(pdf.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    
                    Text(pdf.formattedSize)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                
                Divider()
                
                // Size selector
                VStack(alignment: .leading, spacing: 12) {
                    Text("Maximum file size per part")
                        .font(.headline)
                    
                    Picker("Size", selection: $splitSize) {
                        Text("25 MB").tag(25)
                        Text("50 MB").tag(50)
                        Text("100 MB").tag(100)
                    }
                    .pickerStyle(.segmented)
                    
                    let estimatedParts = max(1, Int(ceil(Double(pdf.fileSize) / Double(splitSize * 1024 * 1024))))
                    Text("Estimated parts: \(estimatedParts)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                
                if isSplitting {
                    VStack(spacing: 12) {
                        ProgressView(value: progress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .orange))
                        
                        Text("Splitting... \(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
                
                Spacer()
                
                // Split button
                Button(action: onSplit) {
                    HStack {
                        Image(systemName: "scissors")
                        Text("Split PDF")
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .cornerRadius(12)
                }
                .disabled(isSplitting)
                .padding()
            }
            .navigationTitle("Split PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Kindle Web Instructions View

struct KindleWebInstructionsView: View {
    let pdf: ConvertedPDF
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "globe.americas.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.blue)
                        
                        Text("Send to Kindle Website")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("File: \(pdf.name)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    
                    Divider()
                    
                    // Instructions
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Follow these steps:")
                            .font(.headline)
                        
                        instructionStep(1, "Open Send to Kindle Website", "We'll open Amazon's Send to Kindle page in Safari")
                        instructionStep(2, "Sign in to Amazon", "Use your Amazon account to log in")
                        instructionStep(3, "Upload Your File", "Tap 'Select Files' and find your PDF")
                        instructionStep(4, "Send to Device", "Choose your Kindle device and send!")
                    }
                    .padding()
                    
                    // Buttons
                    VStack(spacing: 12) {
                        Button(action: openSendToKindleWebsite) {
                            HStack {
                                Image(systemName: "safari.fill")
                                Text("Open Send to Kindle Website")
                            }
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(12)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Send via Website")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    private func instructionStep(_ number: Int, _ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 24, height: 24)
                Text("\(number)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func openSendToKindleWebsite() {
        if let url = URL(string: "https://www.amazon.com/sendtokindle") {
            UIApplication.shared.open(url)
        }
        dismiss()
    }
}

#Preview {
    LibraryView()
        .environmentObject(ConversionManager())
}

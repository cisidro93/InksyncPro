import SwiftUI
import MessageUI

struct LibraryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var selectedPDF: ConvertedPDF?
    @State private var showingActionSheet = false
    @State private var showingShareSheet = false
    @State private var showingMailComposer = false
    @State private var showingSplitOptions = false
    @State private var showingDeleteAlert = false
    @State private var showingLargeFileOptions = false
    @State private var showingKindleInstructions = false
    @State private var pdfToDelete: ConvertedPDF?
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
                    pdfListView
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !conversionManager.convertedPDFs.isEmpty {
                        EditButton()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showingShareSheet) {
            if let pdf = selectedPDF {
                ShareSheet(items: [pdf.url])
            }
        }
        .sheet(isPresented: $showingMailComposer) {
            if let pdf = selectedPDF {
                KindleMailComposer(pdfURL: pdf.url, kindleEmail: conversionManager.kindleEmail)
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
        .confirmationDialog("Send to Kindle Options", isPresented: $showingLargeFileOptions, titleVisibility: .visible) {
            if let pdf = selectedPDF {
                let fileSizeMB = Double(pdf.fileSize) / (1024 * 1024)
                
                Button("Share to Kindle App") {
                    shareToKindleApp(url: pdf.url)
                }
                
                Button("Use Send to Kindle Website") {
                    showingKindleInstructions = true
                }
                
                if fileSizeMB > 200 {
                    Button("Split into Smaller Parts (Recommended)") {
                        showingSplitOptions = true
                    }
                } else {
                    Button("Split into Smaller Parts") {
                        showingSplitOptions = true
                    }
                }
                
                Button("Cancel", role: .cancel) { }
            }
        } message: {
            if let pdf = selectedPDF {
                let fileSizeMB = Double(pdf.fileSize) / (1024 * 1024)
                if fileSizeMB > 200 {
                    Text("This file (\(pdf.formattedSize)) exceeds Amazon's 200MB limit. We recommend splitting it into smaller parts.")
                } else {
                    Text("This file (\(pdf.formattedSize)) is too large for email (50MB limit). Choose an alternative method.")
                }
            }
        }
    }
    
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
    
    private var pdfListView: some View {
        List {
            ForEach(conversionManager.convertedPDFs) { pdf in
                EnhancedPDFRowView(pdf: pdf)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedPDF = pdf
                        showingActionSheet = true
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
                            sendToKindle()
                        } label: {
                            Label("Kindle", systemImage: "arrow.up.forward")
                        }
                        .tint(.orange)
                    }
            }
            .onDelete(perform: deletePDFs)
        }
        .listStyle(.insetGrouped)
        .confirmationDialog("PDF Options", isPresented: $showingActionSheet, titleVisibility: .visible) {
            Button("Send to Kindle") { sendToKindle() }
            Button("Share") { showingShareSheet = true }
            Button("Split into Parts") { showingSplitOptions = true }
            Button("Delete", role: .destructive) {
                pdfToDelete = selectedPDF
                showingDeleteAlert = true
            }
            Button("Cancel", role: .cancel) { }
        }
    }
    
    // MARK: - Smart Send to Kindle Logic
    
    private func sendToKindle() {
        guard let pdf = selectedPDF else { return }
        
        let fileSizeMB = Double(pdf.fileSize) / (1024 * 1024)
        
        if fileSizeMB <= 50 {
            // Small file - use email directly
            if MFMailComposeViewController.canSendMail() {
                showingMailComposer = true
            } else {
                // No mail configured - show options
                showingLargeFileOptions = true
            }
        } else {
            // Large file - show options
            showingLargeFileOptions = true
        }
    }
    
    private func shareToKindleApp(url: URL) {
        // Create activity view controller for sharing to Kindle app
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        
        // Get the root view controller
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            
            // For iPad - set up popover presentation
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

// MARK: - Enhanced PDF Row View with File Size Indicators

struct EnhancedPDFRowView: View {
    let pdf: ConvertedPDF
    
    private var fileSizeMB: Double {
        Double(pdf.fileSize) / (1024 * 1024)
    }
    
    private var fileSizeCategory: FileSizeCategory {
        if fileSizeMB <= 50 {
            return .small
        } else if fileSizeMB <= 200 {
            return .large
        } else {
            return .tooLarge
        }
    }
    
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 50, height: 65)
                
                Image(systemName: "doc.fill")
                    .font(.title2)
                    .foregroundColor(.red)
                
                // File size indicator badge
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: fileSizeCategory.iconName)
                            .font(.caption2)
                            .foregroundColor(fileSizeCategory.color)
                            .background(
                                Circle()
                                    .fill(.white)
                                    .frame(width: 16, height: 16)
                            )
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(pdf.name)
                    .font(.headline)
                    .lineLimit(2)
                
                HStack(spacing: 8) {
                    Label(pdf.formattedSize, systemImage: "doc")
                        .font(.caption)
                        .foregroundColor(fileSizeCategory.color)
                    
                    Label("\(pdf.pageCount) pages", systemImage: "book.pages")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 4) {
                    Text(pdf.dateAdded.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    // Send method indicator
                    Text(fileSizeCategory.sendMethod)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(fileSizeCategory.color.opacity(0.2))
                        .foregroundColor(fileSizeCategory.color)
                        .cornerRadius(4)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - File Size Category Helper

enum FileSizeCategory {
    case small     // ≤ 50MB
    case large     // 50-200MB
    case tooLarge  // > 200MB
    
    var color: Color {
        switch self {
        case .small: return .green
        case .large: return .orange
        case .tooLarge: return .red
        }
    }
    
    var iconName: String {
        switch self {
        case .small: return "checkmark.circle.fill"
        case .large: return "exclamationmark.triangle.fill"
        case .tooLarge: return "xmark.circle.fill"
        }
    }
    
    var sendMethod: String {
        switch self {
        case .small: return "Email"
        case .large: return "App/Web"
        case .tooLarge: return "Split Required"
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
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
                    
                    Divider()
                    
                    // Instructions
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Follow these steps:")
                            .font(.headline)
                        
                        InstructionStep(
                            number: 1,
                            title: "Open Send to Kindle Website",
                            description: "We'll open Amazon's Send to Kindle page in Safari"
                        )
                        
                        InstructionStep(
                            number: 2,
                            title: "Sign in to Amazon",
                            description: "Use your Amazon account to log in"
                        )
                        
                        InstructionStep(
                            number: 3,
                            title: "Upload Your File",
                            description: "Tap 'Select Files' and find your converted PDF in the Files app under 'ComicToPDF'"
                        )
                        
                        InstructionStep(
                            number: 4,
                            title: "Send to Device",
                            description: "Choose your Kindle device and send!"
                        )
                    }
                    .padding()
                    
                    // Action buttons
                    VStack(spacing: 12) {
                        Button(action: openSendToKindleWebsite) {
                            HStack {
                                Image(systemName: "safari.fill")
                                Text("Open Send to Kindle Website")
                            }
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .cornerRadius(12)
                        }
                        
                        Button(action: openFiles) {
                            HStack {
                                Image(systemName: "folder.fill")
                                Text("Open Files App (to locate PDF)")
                            }
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue.opacity(0.1))
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
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func openSendToKindleWebsite() {
        if let url = URL(string: "https://www.amazon.com/sendtokindle") {
            UIApplication.shared.open(url)
        }
        dismiss()
    }
    
    private func openFiles() {
        // This opens the Files app
        if let url = URL(string: "shareddocuments://") {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Instruction Step View

struct InstructionStep: View {
    let number: Int
    let title: String
    let description: String
    
    var body: some View {
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
            
            Spacer()
        }
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

// MARK: - Kindle Mail Composer

struct KindleMailComposer: UIViewControllerRepresentable {
    let pdfURL: URL
    let kindleEmail: String
    
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients([kindleEmail])
        composer.setSubject("Convert")
        composer.setMessageBody("Sent from Comic to PDF Converter", isHTML: false)
        
        if let pdfData = try? Data(contentsOf: pdfURL) {
            composer.addAttachmentData(pdfData, mimeType: "application/pdf", fileName: pdfURL.lastPathComponent)
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
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.orange)
                    
                    Text(pdf.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    
                    Text("Current size: \(pdf.formattedSize)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Maximum part size")
                        .font(.headline)
                    
                    Picker("Split Size", selection: $splitSize) {
                        Text("10 MB").tag(10)
                        Text("25 MB").tag(25)
                        Text("50 MB (Kindle limit)").tag(50)
                    }
                    .pickerStyle(.segmented)
                    
                    Text("Files will be split into parts no larger than \(splitSize) MB each")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                
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
                
                Button(action: onSplit) {
                    HStack {
                        Image(systemName: "scissors")
                        Text("Split PDF")
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.orange)
                    .cornerRadius(12)
                }
                .disabled(isSplitting)
                .padding()
            }
            .navigationTitle("Split PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    LibraryView()
        .environmentObject(ConversionManager())
}

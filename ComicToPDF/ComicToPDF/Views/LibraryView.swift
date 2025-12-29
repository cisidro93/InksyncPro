import SwiftUI
import MessageUI

// MARK: - Library View

struct LibraryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var selectedPDF: ConvertedPDF?
    @State private var showingActionSheet = false
    @State private var showingShareSheet = false
    @State private var showingMailComposer = false
    @State private var showingSplitOptions = false
    @State private var showingDeleteAlert = false
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
                ToolbarItem(placement: .navigationBarTrailing) {
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
                PDFRowView(pdf: pdf)
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
    
    private func sendToKindle() {
        guard let pdf = selectedPDF else { return }
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: pdf.url.path)[.size] as? Int64) ?? 0
        let fileSizeMB = Double(fileSize) / (1024 * 1024)
        
        if fileSizeMB > 50 {
            showingSplitOptions = true
        } else if MFMailComposeViewController.canSendMail() {
            showingMailComposer = true
        } else {
            showingShareSheet = true
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
    
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 50, height: 65)
                
                Image(systemName: "doc.fill")
                    .font(.title2)
                    .foregroundColor(.red)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(pdf.name)
                    .font(.headline)
                    .lineLimit(2)
                
                HStack(spacing: 8) {
                    Label(pdf.formattedSize, systemImage: "doc")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
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

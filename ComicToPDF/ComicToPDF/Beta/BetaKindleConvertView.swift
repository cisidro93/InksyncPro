import SwiftUI
import MessageUI
import SwiftData

struct BetaKindleConvertView: View {
    @EnvironmentObject var libraryStore: BetaLibraryStore
    @EnvironmentObject var kindleService: BetaKindleService
    
    @AppStorage("kindleEmail") private var kindleEmail: String = ""
    @State private var showingMailCompose = false
    @State private var mailAttachmentURL: URL?
    @State private var activeConversionBookID: UUID?
    
    // Share Sheet State
    @State private var shareURL: URL?
    @State private var showingShareSheet = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 1. Wi-Fi Sideload Server Card
                    wifiServerCard
                    
                    // 2. Kindle Email Settings Card
                    emailSettingsCard
                    
                    // 3. Conversion Queue / Book List
                    conversionQueueCard
                }
                .padding()
            }
            .navigationTitle("Kindle Sideload")
            .sheet(isPresented: $showingMailCompose) {
                if let url = mailAttachmentURL {
                    BetaMailComposeView(recipient: kindleEmail, fileURL: url, isPresented: $showingMailCompose)
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let url = shareURL {
                    BetaShareSheet(activityItems: [url])
                }
            }
        }
    }
    
    // MARK: - Wi-Fi Server Card
    
    private var wifiServerCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Image(systemName: "wifi")
                    .font(.title2)
                    .foregroundStyle(.orange)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Direct Wi-Fi Sideload")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Serve books directly to Kindle Web Browser")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                
                Spacer()
                
                Toggle("", isOn: Binding(
                    get: { kindleService.isServerRunning },
                    set: { isRunning in
                        if isRunning {
                            kindleService.startServer()
                        } else {
                            kindleService.stopServer()
                        }
                    }
                ))
                .tint(.orange)
            }
            
            if kindleService.isServerRunning {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().background(Color.white.opacity(0.1))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Local Server Address")
                                .font(.caption)
                                .foregroundStyle(.gray)
                            Text(kindleService.serverURLString)
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button {
                            UIPasteboard.general.string = kindleService.serverURLString
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(.gray)
                        }
                    }
                    
                    HStack {
                        Text("Active Connections:")
                            .font(.caption)
                            .foregroundStyle(.gray)
                        Text("\(kindleService.activeConnections)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Instructions:")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                        Text("1. Connect your Kindle and this device to the same Wi-Fi network.\n2. Open the Experimental Web Browser on your Kindle.\n3. Navigate to the address displayed above.\n4. Tap 'Download' next to any book to sideload it.")
                            .font(.system(size: 11))
                            .foregroundStyle(.gray)
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding()
        .background(Color(hex: "#1E1E24"))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
    
    // MARK: - Email Settings Card
    
    private var emailSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Send to Kindle via Email", systemImage: "envelope.fill")
                .font(.headline)
                .foregroundStyle(.white)
            
            Text("Amazon allows sending document attachments to your Kindle's unique @kindle.com email address.")
                .font(.caption)
                .foregroundStyle(.gray)
            
            TextField("Your @kindle.com Email", text: $kindleEmail)
                .padding()
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)
                .foregroundStyle(.white)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            
            Text("Note: Ensure you add your personal sending email to Amazon's 'Approved Personal Document E-mail List' in your Amazon account preferences.")
                .font(.system(size: 10))
                .foregroundStyle(.orange.opacity(0.8))
        }
        .padding()
        .background(Color(hex: "#1E1E24"))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
    
    // MARK: - Conversion Book List
    
    private var conversionQueueCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Convert & Send Books")
                .font(.headline)
                .foregroundStyle(.white)
            
            if libraryStore.books.isEmpty {
                Text("No books available for conversion.")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(libraryStore.books) { book in
                    HStack(spacing: 12) {
                        BetaBookCoverView(book: book)
                            .frame(width: 40, height: 55)
                            .clipped()
                            .cornerRadius(4)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("\(book.contentType.rawValue) • \(book.formattedSize)")
                                .font(.caption)
                                .foregroundStyle(.gray)
                            
                            if activeConversionBookID == book.id && kindleService.isConverting {
                                ProgressView(value: kindleService.conversionProgress)
                                    .accentColor(.orange)
                                    .frame(height: 3)
                            }
                        }
                        
                        Spacer()
                        
                        // Convert Button
                        if activeConversionBookID == book.id && kindleService.isConverting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                        } else {
                            Button {
                                performConversion(for: book)
                            } label: {
                                Text("Convert")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.orange)
                                    .cornerRadius(6)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    Divider().background(Color.white.opacity(0.05))
                }
            }
        }
        .padding()
        .background(Color(hex: "#1E1E24"))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
    
    // MARK: - Actions
    
    private func performConversion(for book: BetaBook) {
        activeConversionBookID = book.id
        
        Task {
            do {
                let epubURL = try await kindleService.convertToEPUB(book: book)
                
                await MainActor.run {
                    activeConversionBookID = nil
                    if !kindleEmail.isEmpty && MFMailComposeViewController.canSendMail() {
                        mailAttachmentURL = epubURL
                        showingMailCompose = true
                    } else {
                        // Fallback to share sheet
                        shareURL = epubURL
                        showingShareSheet = true
                    }
                }
            } catch {
                print("BetaKindleConvertView: Conversion error: \(error)")
                await MainActor.run {
                    activeConversionBookID = nil
                }
            }
        }
    }
}

// MARK: - Mail Compose ViewController Representable

struct BetaMailComposeView: UIViewControllerRepresentable {
    let recipient: String
    let fileURL: URL
    @Binding var isPresented: Bool
    
    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        @Binding var isPresented: Bool
        
        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }
        
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            isPresented = false
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }
    
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([recipient])
        vc.setSubject("Send to Kindle: \(fileURL.deletingPathExtension().lastPathComponent)")
        vc.setMessageBody("Here is your comic/manga converted for Kindle fixed layout.", isHTML: false)
        
        if let data = try? Data(contentsOf: fileURL) {
            vc.addAttachmentData(data, mimeType: "application/epub+zip", fileName: fileURL.lastPathComponent)
        }
        
        return vc
    }
    
    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
}

// MARK: - Share Sheet Representable

struct BetaShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var excludedActivityTypes: [UIActivity.ActivityType]? = nil
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.excludedActivityTypes = excludedActivityTypes
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

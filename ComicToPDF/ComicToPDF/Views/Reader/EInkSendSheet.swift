import SwiftUI

struct RegisteredDevice: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var kindleEmail: String?
}

struct EInkSendSheet: View {
    let pdf: ConvertedPDF
    @Environment(\.presentationMode) var presentation
    @EnvironmentObject var conversionManager: ConversionManager
    
    @StateObject private var kindleService = KindlePersonalDocumentService.shared
    @State private var emailInput: String = ""
    @State private var deliveryStatus: String = "Ready to send"
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                
                Image(systemName: getIcon())
                    .font(.system(size: 60))
                    .foregroundColor(getColor())
                    .padding(.top, 20)
                
                Text("Send to E-Ink")
                    .font(.title2).bold()
                
                Text(pdf.name)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                if pdf.contentKind == .document && pdf.documentSubtype == .magazine {
                    magazineChoiceCard
                } else if pdf.contentKind == .book || pdf.contentKind == .document {
                    amazonSendCard
                } else {
                    comicSendCard
                }
                
                Spacer()
            }
            .navigationBarItems(trailing: Button("Cancel") { presentation.wrappedValue.dismiss() })
            .sheet(isPresented: $kindleService.isPresentingMail) {
                if let url = kindleService.fileURLToSend, let email = kindleService.kindleEmail {
                    MailComposeView(fileURL: url, toEmail: email)
                }
            }
            .sheet(isPresented: $kindleService.isPresentingShare) {
                if let url = kindleService.fileURLToSend {
                    ShareActivityView(activityItems: [url])
                }
            }
        }
    }
    
    var amazonSendCard: some View {
        VStack(spacing: 16) {
            TextField("Kindle Email Address (e.g. name@kindle.com)", text: $emailInput)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                .padding(.horizontal, 24)
            
            Button(action: {
                Task {
                    do {
                        deliveryStatus = "Preparing file..."
                        try await kindleService.send(fileURL: pdf.url, kindleEmail: emailInput.isEmpty ? nil : emailInput)
                        deliveryStatus = "Handed off to iOS"
                    } catch {
                        deliveryStatus = error.localizedDescription
                    }
                }
            }) {
                HStack {
                    Image(systemName: "paperplane.fill")
                    Text("Send via Amazon")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
                .padding(.horizontal, 24)
            }
            
            Text(deliveryStatus)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    var comicSendCard: some View {
        VStack(spacing: 16) {
            Button(action: {
                // Route to KFX/WebDAV logic via ConversionManager (already built)
                presentation.wrappedValue.dismiss()
            }) {
                HStack {
                    Image(systemName: "arrow.up.forward.square")
                    Text("Export Pipeline")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.orange)
                .foregroundColor(.white)
                .cornerRadius(12)
                .padding(.horizontal, 24)
            }
        }
    }
    
    var magazineChoiceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How do you want to send this?")
                .font(.headline)
                .padding(.horizontal, 24)
            
            Button(action: { /* Send RAW */ }) {
                VStack(alignment: .leading) {
                    Text("📄 Send original PDF")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Preserves layout · up to 200MB")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)
            }
            .padding(.horizontal, 24)
            
            Button(action: { /* Run ImageProcessor & Send */ }) {
                VStack(alignment: .leading) {
                    Text("🖼 Optimise for Kindle")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Smaller file · faster transfer")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)
            }
            .padding(.horizontal, 24)
        }
    }
    
    func getIcon() -> String {
        switch pdf.contentKind {
        case .comic: return "book.closed.fill"
        case .book: return "book.fill"
        case .document: return "doc.fill"
        }
    }
    
    func getColor() -> Color {
        switch pdf.contentKind {
        case .comic: return .orange
        case .book: return .green
        case .document: return .blue
        }
    }
}

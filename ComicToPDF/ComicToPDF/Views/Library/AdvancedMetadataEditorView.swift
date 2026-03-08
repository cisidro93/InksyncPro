import SwiftUI
import PhotosUI

// MARK: - Reusable Glass Card
struct CustomGlassCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(Theme.blue)
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding(.bottom, 4)
            
            content
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

// MARK: - Reusable Glass TextField
struct GlassTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(Theme.textSecondary)
                .textCase(.uppercase)
            
            TextField(placeholder, text: $text)
                .keyboardType(keyboardType)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.3))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                )
                .foregroundColor(.white)
        }
    }
}

struct AdvancedMetadataEditorView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    let pdf: ConvertedPDF
    
    // Form State
    @State private var title: String = ""
    @State private var author: String = ""
    @State private var publisher: String = ""
    @State private var series: String = ""
    @State private var volume: String = ""
    @State private var issueNumber: String = ""
    @State private var tags: [String] = []
    
    // Custom Cover State
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var customCoverImage: UIImage? = nil
    @State private var currentCoverImage: UIImage? = nil
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    coverImageSection
                    coreMetadataSection
                    organizationSection
                    tagsSection
                    contentEditorHook
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Edit Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Theme.textSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { saveMetadata() }
                        .fontWeight(.bold)
                        .foregroundColor(Theme.blue)
                }
            }
            .onAppear { loadInitialData() }
            .onChange(of: selectedPhotoItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self), let uiImage = UIImage(data: data) {
                        await MainActor.run { self.customCoverImage = uiImage }
                    }
                }
            }
        }
    @ViewBuilder
    private var coverImageSection: some View {
        CustomGlassCard(title: "Cover Image", icon: "photo.artframe") {
            HStack {
                Spacer()
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let customCover = customCoverImage {
                            Image(uiImage: customCover)
                                .resizable()
                                .scaledToFill()
                        } else if let currentCover = currentCoverImage {
                            Image(uiImage: currentCover)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Rectangle()
                                .fill(Color.black.opacity(0.3))
                                .overlay(Image(systemName: "photo").font(.largeTitle).foregroundColor(Theme.textSecondary))
                        }
                    }
                    .frame(width: 160, height: 230)
                    .cornerRadius(12)
                    .clipped()
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                        Image(systemName: "camera.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.white, Theme.blue)
                            .shadow(radius: 4)
                            .offset(x: 12, y: 12)
                    }
                }
                Spacer()
            }
        }
    }
    
    @ViewBuilder
    private var coreMetadataSection: some View {
        CustomGlassCard(title: "Core Data", icon: "info.circle.fill") {
            VStack(spacing: 16) {
                GlassTextField(title: "Title", placeholder: "e.g. Batman: Year One", text: $title)
                GlassTextField(title: "Author / Writer", placeholder: "e.g. Frank Miller", text: $author)
                GlassTextField(title: "Publisher", placeholder: "e.g. DC Comics", text: $publisher)
            }
        }
    }
    
    @ViewBuilder
    private var organizationSection: some View {
        CustomGlassCard(title: "Organization", icon: "books.vertical.fill") {
            VStack(spacing: 16) {
                GlassTextField(title: "Series Name", placeholder: "e.g. Batman", text: $series)
                
                HStack(spacing: 16) {
                    GlassTextField(title: "Volume", placeholder: "e.g. 1", text: $volume, keyboardType: .numbersAndPunctuation)
                    GlassTextField(title: "Issue", placeholder: "e.g. 404", text: $issueNumber, keyboardType: .numbersAndPunctuation)
                }
            }
        }
    }
    
    @ViewBuilder
    private var tagsSection: some View {
        CustomGlassCard(title: "Tags", icon: "tag.fill") {
            TagEditorView(tags: $tags)
                .padding()
                .background(Color.black.opacity(0.3))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.05), lineWidth: 1))
        }
    }
    
    @ViewBuilder
    private var contentEditorHook: some View {
        if pdf.contentType == .pdf || pdf.contentType == .book {
            CustomGlassCard(title: "Advanced Editing", icon: "scissors") {
                NavigationLink(destination: getEditorView(for: pdf)) {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                        Text("Edit Content (Modify Source Data)")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .background(Theme.blue.opacity(0.8))
                    .cornerRadius(10)
                }
            }
        }
    }

    @ViewBuilder
    private func getEditorView(for pdf: ConvertedPDF) -> some View {
        if pdf.contentType == .book {
            EPUBContentEditorView(pdf: pdf)
        } else {
            PDFContentEditorView(pdf: pdf)
        }
    }
    
    private func loadInitialData() {
        self.title = pdf.metadata.title
        self.author = pdf.metadata.author ?? pdf.metadata.writer ?? ""
        self.publisher = pdf.metadata.publisher ?? ""
        self.series = pdf.metadata.series ?? ""
        self.volume = pdf.metadata.volume ?? ""
        self.issueNumber = pdf.metadata.issueNumber ?? ""
        self.tags = pdf.metadata.tags
        
        Task {
            if let image = await conversionManager.loadCoverThumbnail(for: pdf) {
                await MainActor.run { self.currentCoverImage = image }
            }
        }
    }
    
    private func saveMetadata() {
        var updatedMeta = pdf.metadata
        updatedMeta.title = title.isEmpty ? pdf.name : title
        updatedMeta.author = author.isEmpty ? nil : author
        updatedMeta.publisher = publisher.isEmpty ? nil : publisher
        updatedMeta.series = series.isEmpty ? nil : series
        updatedMeta.volume = volume.isEmpty ? nil : volume
        updatedMeta.issueNumber = issueNumber.isEmpty ? nil : issueNumber
        updatedMeta.tags = tags
        
        conversionManager.updateMetadata(for: pdf, with: updatedMeta, newCover: customCoverImage)
        dismiss()
    }
}

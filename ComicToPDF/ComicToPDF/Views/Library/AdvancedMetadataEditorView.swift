import SwiftUI
import PhotosUI

// MARK: - Reusable Glass Card
struct CustomGlassCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    
    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: isPad ? 18 : 15, weight: .semibold))
                    .foregroundColor(Color.inkBlue)
                Text(title)
                    .font(.system(size: isPad ? 17 : 15, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.inkText)
            }
            .padding(.bottom, 4)
            
            content
        }
        .padding(isPad ? 22 : 18)
        .background(Color.inkSurfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .inkSpecularBorder(cornerRadius: 16)
    }
}

// MARK: - Reusable Glass TextField
struct GlassTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    
    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: isPad ? 12.5 : 11, weight: .semibold))
                .foregroundColor(Color.inkSecondary)
                .textCase(.uppercase)
                .tracking(0.6)
            
            TextField(placeholder, text: $text)
                .keyboardType(keyboardType)
                .font(.system(size: isPad ? 16 : 14))
                .padding(.horizontal, 16)
                .padding(.vertical, isPad ? 14 : 12)
                .background(Color.inkSurface)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.inkSecondary.opacity(0.15), lineWidth: 1)
                )
                .foregroundColor(Color.inkText)
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
    @State private var rawSourceCoverImage: UIImage? = nil
    @State private var hasSpreadCover: Bool = false
    @State private var selectedSpreadMode: CoverSpreadCropMode = .rightHalf
    
    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    InkSheetDragPill()
                        .padding(.top, 4)

                    coverImageSection
                    coreMetadataSection
                    organizationSection
                    tagsSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .frame(maxWidth: isPad ? 660 : .infinity)
            }
            .background(Color.inkBackground.ignoresSafeArea())
            .navigationTitle("Edit Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: isPad ? 16 : 15))
                        .foregroundColor(Color.inkSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        HapticEngine.success()
                        saveMetadata()
                    }
                    .font(.system(size: isPad ? 16 : 15, weight: .bold))
                    .foregroundColor(Color.inkBlue)
                }
            }
            .onAppear { loadInitialData() }
            .onChange(of: selectedPhotoItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self), let uiImage = UIImage(data: data) {
                        await MainActor.run {
                            self.customCoverImage = uiImage
                            self.rawSourceCoverImage = uiImage
                            self.hasSpreadCover = ImageProcessor.isDoublePageSpread(size: uiImage.size)
                        }
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var coverImageSection: some View {
        CustomGlassCard(title: "Cover Image", icon: "photo.artframe") {
            VStack(spacing: 14) {
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
                                    .fill(Color.inkSurface)
                                    .overlay(Image(systemName: "photo").font(.largeTitle).foregroundColor(Theme.textSecondary))
                            }
                        }
                        .frame(width: 160, height: 230)
                        .cornerRadius(12)
                        .clipped()
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                        
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                            Image(systemName: "camera.circle.fill")
                                .font(.system(size: isPad ? 38 : 34))
                                .foregroundStyle(.white, Color.inkBlue)
                                .shadow(radius: 4)
                                .offset(x: 12, y: 12)
                        }
                    }
                    Spacer()
                }

                if hasSpreadCover {
                    VStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Color.inkBlue)
                            Text("Double-Page Spread Cover Detected")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(Color.inkText)
                        }

                        HStack(spacing: 8) {
                            spreadCropButton(title: "Right (Front)", icon: "rectangle.righthalf.inset.filled", mode: .rightHalf)
                            spreadCropButton(title: "Left (Front)", icon: "rectangle.lefthalf.inset.filled", mode: .leftHalf)
                            spreadCropButton(title: "Full", icon: "rectangle.split.2x1", mode: .fullSpread)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func spreadCropButton(title: String, icon: String, mode: CoverSpreadCropMode) -> some View {
        let isSelected = selectedSpreadMode == mode
        return Button {
            HapticEngine.selection()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                selectedSpreadMode = mode
                if let raw = rawSourceCoverImage {
                    customCoverImage = ImageProcessor.cropSpreadCover(image: raw, mode: mode)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Color.inkBlue : Color.inkSurface)
            .foregroundColor(isSelected ? .white : Color.inkSecondary)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.clear : Color.primary.opacity(0.12), lineWidth: 1)
            )
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
                .background(Color.inkSurface)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
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
        self.selectedSpreadMode = pdf.metadata.coverSpreadMode ?? .rightHalf
        
        let fileURL = pdf.url
        Task {
            if let image = await conversionManager.loadCoverThumbnail(for: pdf) {
                await MainActor.run { self.currentCoverImage = image }
            }
            let raw = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                PhysicalFileSystemRouter.extractCoverImageStatic(from: fileURL, cropSpread: false)
            }.value
            if let raw = raw {
                await MainActor.run {
                    self.rawSourceCoverImage = raw
                    if ImageProcessor.isDoublePageSpread(size: raw.size) {
                        self.hasSpreadCover = true
                    }
                }
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
        if hasSpreadCover {
            updatedMeta.coverSpreadMode = selectedSpreadMode
        }
        
        conversionManager.updateMetadata(for: pdf, with: updatedMeta, newCover: customCoverImage)
        dismiss()
    }
}

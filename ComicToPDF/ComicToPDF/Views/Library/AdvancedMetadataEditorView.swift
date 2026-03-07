import SwiftUI
import PhotosUI

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
            Form {
                // MARK: - Cover Image Section
                Section {
                    HStack {
                        Spacer()
                        ZStack(alignment: .bottomTrailing) {
                            if let customCover = customCoverImage {
                                Image(uiImage: customCover)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 140, height: 200)
                                    .cornerRadius(8)
                                    .clipped()
                            } else if let currentCover = currentCoverImage {
                                Image(uiImage: currentCover)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 140, height: 200)
                                    .cornerRadius(8)
                                    .clipped()
                            } else {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(width: 140, height: 200)
                                    .cornerRadius(8)
                                    .overlay(Image(systemName: "photo").font(.largeTitle).foregroundColor(.secondary))
                            }
                            
                            PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.blue)
                                    .background(Circle().fill(Color.white))
                                    .offset(x: 10, y: 10)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                } header: {
                    Text("Cover Image")
                }
                
                // MARK: - Core Metadata Section
                Section(header: Text("Core Data")) {
                    TextField("Title", text: $title)
                    TextField("Author / Writer", text: $author)
                    TextField("Publisher", text: $publisher)
                }
                
                // MARK: - Series & Organization Section
                Section(header: Text("Organization")) {
                    TextField("Series Name", text: $series)
                    TextField("Volume Number", text: $volume)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Issue Number", text: $issueNumber)
                        .keyboardType(.numbersAndPunctuation)
                }
                
                // MARK: - Tags Section
                Section(header: Text("Tags")) {
                    TagEditorView(tags: $tags)
                }
            }
            .navigationTitle("Edit Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { saveMetadata() }
                        .fontWeight(.bold)
                }
            }
            .onAppear {
                loadInitialData()
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self), let uiImage = UIImage(data: data) {
                        await MainActor.run { self.customCoverImage = uiImage }
                    }
                }
            }
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
        // Don't overwrite if not user changed and was null, but let's just save
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

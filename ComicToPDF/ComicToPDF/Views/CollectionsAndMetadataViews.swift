import SwiftUI

// ============================================================================
// MARK: - COLLECTIONS VIEW
// ============================================================================

struct CollectionsView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var showingCreateCollection = false
    @State private var showingEditCollection = false
    @State private var collectionToEdit: PDFCollection?
    @State private var showingDeleteAlert = false
    @State private var collectionToDelete: PDFCollection?
    
    var body: some View {
        NavigationView {
            List {
                NavigationLink(destination: CollectionDetailView(collection: nil)) {
                    HStack(spacing: 12) {
                        ZStack { Circle().fill(Color.gray.opacity(0.2)).frame(width: 44, height: 44); Image(systemName: "tray.full.fill").foregroundColor(.gray) }
                        VStack(alignment: .leading) { Text("All PDFs").font(.headline); Text("\(conversionManager.convertedPDFs.count) items").font(.caption).foregroundColor(.secondary) }
                    }
                }
                NavigationLink(destination: CollectionDetailView(collection: nil, uncategorizedOnly: true)) {
                    HStack(spacing: 12) {
                        ZStack { Circle().fill(Color.orange.opacity(0.2)).frame(width: 44, height: 44); Image(systemName: "questionmark.folder.fill").foregroundColor(.orange) }
                        VStack(alignment: .leading) { Text("Uncategorized").font(.headline); Text("\(uncategorizedCount) items").font(.caption).foregroundColor(.secondary) }
                    }
                }
                Section {
                    ForEach(conversionManager.collections) { collection in
                        NavigationLink(destination: CollectionDetailView(collection: collection)) { CollectionRow(collection: collection, itemCount: itemCount(for: collection)) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { collectionToDelete = collection; showingDeleteAlert = true } label: { Label("Delete", systemImage: "trash") }
                            Button { collectionToEdit = collection; showingEditCollection = true } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                        }
                    }
                    Button(action: { showingCreateCollection = true }) { HStack { Image(systemName: "plus.circle.fill").foregroundColor(.green); Text("Create Collection") } }
                } header: { Text("Collections") }
            }
            .navigationTitle("Collections")
            .sheet(isPresented: $showingCreateCollection) { CreateEditCollectionView(mode: .create) }
            .sheet(isPresented: $showingEditCollection) { if let collection = collectionToEdit { CreateEditCollectionView(mode: .edit(collection)) } }
            .alert("Delete Collection?", isPresented: $showingDeleteAlert) { Button("Cancel", role: .cancel) { }; Button("Delete", role: .destructive) { if let collection = collectionToDelete { conversionManager.deleteCollection(collection) } } } message: { Text("PDFs in this collection will be moved to Uncategorized.") }
        }.navigationViewStyle(.stack)
    }
    
    private var uncategorizedCount: Int { conversionManager.convertedPDFs.filter { $0.collectionId == nil }.count }
    private func itemCount(for collection: PDFCollection) -> Int { conversionManager.convertedPDFs.filter { $0.collectionId == collection.id }.count }
}

struct CollectionRow: View {
    let collection: PDFCollection
    let itemCount: Int
    var color: Color { colorFor(collection.color) }
    var body: some View {
        HStack(spacing: 12) {
            ZStack { Circle().fill(color.opacity(0.2)).frame(width: 44, height: 44); Image(systemName: collection.icon).foregroundColor(color) }
            VStack(alignment: .leading) { Text(collection.name).font(.headline); Text("\(itemCount) items").font(.caption).foregroundColor(.secondary) }
        }
    }
}

struct CollectionDetailView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let collection: PDFCollection?
    var uncategorizedOnly: Bool = false
    @State private var selectedPDF: ConvertedPDF?
    @State private var showingMoveSheet = false
    
    var pdfs: [ConvertedPDF] {
        if uncategorizedOnly { return conversionManager.convertedPDFs.filter { $0.collectionId == nil } }
        else if let collection = collection { return conversionManager.convertedPDFs.filter { $0.collectionId == collection.id } }
        else { return conversionManager.convertedPDFs }
    }
    var title: String { if uncategorizedOnly { return "Uncategorized" } else if let collection = collection { return collection.name } else { return "All PDFs" } }
    
    var body: some View {
        List {
            ForEach(pdfs) { pdf in
                HStack {
                    VStack(alignment: .leading) { Text(pdf.name).font(.headline); Text("\(pdf.pageCount) pages • \(pdf.formattedSize)").font(.caption).foregroundColor(.secondary) }
                    Spacer()
                }.swipeActions(edge: .leading) { Button { selectedPDF = pdf; showingMoveSheet = true } label: { Label("Move", systemImage: "folder") }.tint(.blue) }
            }
        }.navigationTitle(title).sheet(isPresented: $showingMoveSheet) { if let pdf = selectedPDF { MoveToCollectionView(pdf: pdf) } }
    }
}

struct MoveToCollectionView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss
    let pdf: ConvertedPDF
    
    var body: some View {
        NavigationView {
            List {
                Button(action: { moveTo(nil) }) { HStack { Image(systemName: "questionmark.folder.fill").foregroundColor(.orange); Text("Uncategorized"); Spacer(); if pdf.collectionId == nil { Image(systemName: "checkmark").foregroundColor(.blue) } } }
                ForEach(conversionManager.collections) { collection in
                    Button(action: { moveTo(collection.id) }) { HStack { Image(systemName: collection.icon).foregroundColor(colorFor(collection.color)); Text(collection.name); Spacer(); if pdf.collectionId == collection.id { Image(systemName: "checkmark").foregroundColor(.blue) } } }
                }
            }.navigationTitle("Move to Collection").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Cancel") { dismiss() } } }
        }
    }
    private func moveTo(_ collectionId: UUID?) { conversionManager.movePDFToCollection(pdf, collectionId: collectionId); dismiss() }
}

enum CollectionMode { case create; case edit(PDFCollection) }

struct CreateEditCollectionView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss
    let mode: CollectionMode
    @State private var name = ""
    @State private var selectedIcon = "folder.fill"
    @State private var selectedColor = "blue"
    let icons = ["folder.fill", "book.fill", "star.fill", "heart.fill", "bookmark.fill", "tag.fill", "flame.fill", "bolt.fill", "leaf.fill", "moon.fill", "sun.max.fill", "sparkles"]
    let colors = ["red", "orange", "yellow", "green", "blue", "purple", "pink"]
    var isEditing: Bool { if case .edit = mode { return true }; return false }
    
    var body: some View {
        NavigationView {
            Form {
                Section { TextField("Collection Name", text: $name) }
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 50))], spacing: 12) {
                        ForEach(icons, id: \.self) { icon in
                            Button(action: { selectedIcon = icon }) { Image(systemName: icon).font(.title2).foregroundColor(selectedIcon == icon ? .white : colorFor(selectedColor)).frame(width: 44, height: 44).background(Circle().fill(selectedIcon == icon ? colorFor(selectedColor) : colorFor(selectedColor).opacity(0.2))) }
                        }
                    }.padding(.vertical, 8)
                } header: { Text("Icon") }
                Section {
                    HStack(spacing: 12) {
                        ForEach(colors, id: \.self) { color in
                            Button(action: { selectedColor = color }) { Circle().fill(colorFor(color)).frame(width: 36, height: 36).overlay(Circle().stroke(Color.white, lineWidth: selectedColor == color ? 3 : 0)) }
                        }
                    }.padding(.vertical, 8)
                } header: { Text("Color") }
                Section {
                    HStack(spacing: 12) {
                        ZStack { Circle().fill(colorFor(selectedColor).opacity(0.2)).frame(width: 50, height: 50); Image(systemName: selectedIcon).font(.title2).foregroundColor(colorFor(selectedColor)) }
                        Text(name.isEmpty ? "Collection Name" : name).font(.headline).foregroundColor(name.isEmpty ? .secondary : .primary)
                    }
                } header: { Text("Preview") }
            }
            .navigationTitle(isEditing ? "Edit Collection" : "New Collection").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .navigationBarTrailing) { Button("Save") { save() }.fontWeight(.semibold).disabled(name.isEmpty) } }
            .onAppear { if case .edit(let collection) = mode { name = collection.name; selectedIcon = collection.icon; selectedColor = collection.color } }
        }
    }
    
    private func save() {
        switch mode {
        case .create: conversionManager.createCollection(name: name, icon: selectedIcon, color: selectedColor)
        case .edit(let collection): if let index = conversionManager.collections.firstIndex(where: { $0.id == collection.id }) { conversionManager.collections[index].name = name; conversionManager.collections[index].icon = selectedIcon; conversionManager.collections[index].color = selectedColor }
        }
        dismiss()
    }
}

// ============================================================================
// MARK: - METADATA EDITOR VIEW
// ============================================================================

struct MetadataEditorView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) private var dismiss
    let pdf: ConvertedPDF
    @State private var title: String = ""
    @State private var author: String = ""
    @State private var series: String = ""
    @State private var volume: String = ""
    @State private var genre: String = ""
    @State private var notes: String = ""
    @State private var tagInput: String = ""
    @State private var tags: [String] = []
    let genres = ["Action", "Adventure", "Comedy", "Drama", "Fantasy", "Horror", "Mystery", "Romance", "Sci-Fi", "Slice of Life", "Sports", "Superhero", "Thriller", "Other"]
    
    var body: some View {
        NavigationView {
            Form {
                Section { TextField("Title", text: $title); TextField("Author/Artist", text: $author) } header: { Text("Basic Info") }
                Section { TextField("Series Name", text: $series); TextField("Volume/Issue", text: $volume) } header: { Text("Series Info") }
                Section { Picker("Genre", selection: $genre) { Text("Select Genre").tag(""); ForEach(genres, id: \.self) { g in Text(g).tag(g) } } } header: { Text("Category") }
                Section {
                    HStack { TextField("Add tag", text: $tagInput); Button(action: addTag) { Image(systemName: "plus.circle.fill").foregroundColor(.green) }.disabled(tagInput.isEmpty) }
                    if !tags.isEmpty { FlowLayout(spacing: 8) { ForEach(tags, id: \.self) { tag in TagView(tag: tag) { tags.removeAll { $0 == tag } } } } }
                } header: { Text("Tags") }
                Section { TextEditor(text: $notes).frame(minHeight: 100) } header: { Text("Notes") }
                Section { HStack { Text("File Size"); Spacer(); Text(pdf.formattedSize).foregroundColor(.secondary) }; HStack { Text("Pages"); Spacer(); Text("\(pdf.pageCount)").foregroundColor(.secondary) }; HStack { Text("Added"); Spacer(); Text(pdf.dateAdded.formatted()).foregroundColor(.secondary) } } header: { Text("File Info") }
            }
            .navigationTitle("Edit Metadata").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .navigationBarTrailing) { Button("Save") { save() }.fontWeight(.semibold) } }
            .onAppear { title = pdf.metadata.title.isEmpty ? pdf.name : pdf.metadata.title; author = pdf.metadata.author; series = pdf.metadata.series; volume = pdf.metadata.volume; genre = pdf.metadata.genre; notes = pdf.metadata.notes; tags = pdf.metadata.tags }
        }
    }
    
    private func addTag() { let newTag = tagInput.trimmingCharacters(in: .whitespaces); if !newTag.isEmpty && !tags.contains(newTag) { tags.append(newTag); tagInput = "" } }
    private func save() { let metadata = PDFMetadata(title: title, author: author, series: series, volume: volume, genre: genre, tags: tags, notes: notes); conversionManager.updatePDFMetadata(pdf, metadata: metadata); dismiss() }
}

struct TagView: View {
    let tag: String
    let onDelete: () -> Void
    var body: some View { HStack(spacing: 4) { Text(tag).font(.caption); Button(action: onDelete) { Image(systemName: "xmark.circle.fill").font(.caption) } }.foregroundColor(.blue).padding(.horizontal, 10).padding(.vertical, 6).background(Color.blue.opacity(0.1).cornerRadius(20)) }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing); return result.size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) { let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing); for (index, subview) in subviews.enumerated() { subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified) } }
    struct FlowResult { var size: CGSize = .zero; var positions: [CGPoint] = []; init(in width: CGFloat, subviews: Subviews, spacing: CGFloat) { var x: CGFloat = 0; var y: CGFloat = 0; var rowHeight: CGFloat = 0; for subview in subviews { let size = subview.sizeThatFits(.unspecified); if x + size.width > width && x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }; positions.append(CGPoint(x: x, y: y)); rowHeight = max(rowHeight, size.height); x += size.width + spacing; self.size.width = max(self.size.width, x); self.size.height = y + rowHeight } } }
}

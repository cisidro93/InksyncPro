import SwiftUI
import SwiftData

struct ManuscriptEditorWorkspace: View {
    @Bindable var project: SDManuscriptProject
    @Environment(\.modelContext) private var modelContext
    @Query private var allAnnotations: [SDAnnotation]
    
    @State private var selectedDocumentID: UUID?
    @State private var isInspectorVisible = true
    
    @State private var showingNewDocumentDialog = false
    @State private var newDocumentTitle = ""
    
    // Sort documents by orderIndex
    private var sortedDocuments: [SDManuscriptDocument] {
        project.documents.sorted(by: { $0.orderIndex < $1.orderIndex })
    }
    
    private var selectedDocument: SDManuscriptDocument? {
        project.documents.first(where: { $0.id == selectedDocumentID })
    }
    
    var body: some View {
        NavigationSplitView {
            // Left Pane: Binder
            List(selection: $selectedDocumentID) {
                Section("Chapters") {
                    ForEach(sortedDocuments) { doc in
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundColor(.orange)
                            Text(doc.title)
                            Spacer()
                            Text("\(doc.wordCount) wds")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .tag(doc.id)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedDocumentID = doc.id }
                    }
                    .onMove(perform: moveDocuments)
                    .onDelete(perform: deleteDocuments)
                }
            }
            .navigationTitle("Binder")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingNewDocumentDialog = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        } detail: {
            // Center Pane: Editor & Right Pane: Inspector
            if let document = selectedDocument {
                HStack(spacing: 0) {
                    // Center Pane
                    VStack(spacing: 0) {
                        // Editor Header
                        HStack {
                            Text(document.title)
                                .font(.title2.bold())
                            Spacer()
                            Text("\(document.wordCount) Words")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(8)
                            
                            Button {
                                withAnimation { isInspectorVisible.toggle() }
                            } label: {
                                Image(systemName: "sidebar.right")
                                    .foregroundColor(isInspectorVisible ? .orange : .primary)
                            }
                            .padding(.leading, 8)
                        }
                        .padding()
                        .background(Color(UIColor.systemBackground))
                        
                        Divider()
                        
                        // Editor
                        TextEditor(text: Binding(
                            get: { document.contentMarkdown },
                            set: { newValue in
                                document.contentMarkdown = newValue
                                document.modifiedAt = Date()
                                try? modelContext.save()
                            }
                        ))
                        .font(.system(.body, design: .serif))
                        .padding()
                    }
                    .frame(maxWidth: .infinity)
                    
                    // Right Pane: Inspector
                    if isInspectorVisible {
                        Divider()
                        InspectorPane(document: document, allAnnotations: allAnnotations)
                            .frame(width: 300)
                            .transition(.move(edge: .trailing))
                    }
                }
            } else {
                VStack {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)
                    Text("Select a chapter from the Binder")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .alert("New Chapter", isPresented: $showingNewDocumentDialog) {
            TextField("Chapter Title", text: $newDocumentTitle)
            Button("Create") {
                createDocument()
            }
            Button("Cancel", role: .cancel) {
                newDocumentTitle = ""
            }
        } message: {
            Text("Enter a title for the new chapter or scene.")
        }
    }
    
    private func createDocument() {
        guard !newDocumentTitle.isEmpty else { return }
        let newDoc = SDManuscriptDocument(title: newDocumentTitle, orderIndex: project.documents.count)
        newDoc.project = project
        project.documents.append(newDoc)
        modelContext.insert(newDoc)
        try? modelContext.save()
        selectedDocumentID = newDoc.id
        newDocumentTitle = ""
    }
    
    private func moveDocuments(from source: IndexSet, to destination: Int) {
        var revisedItems = sortedDocuments
        revisedItems.move(fromOffsets: source, toOffset: destination)
        
        for (index, item) in revisedItems.enumerated() {
            item.orderIndex = index
        }
        try? modelContext.save()
    }
    
    private func deleteDocuments(at offsets: IndexSet) {
        for index in offsets {
            let doc = sortedDocuments[index]
            if let idx = project.documents.firstIndex(of: doc) {
                project.documents.remove(at: idx)
                modelContext.delete(doc)
            }
        }
        try? modelContext.save()
    }
}

// MARK: - Inspector Pane
struct InspectorPane: View {
    let document: SDManuscriptDocument
    let allAnnotations: [SDAnnotation]
    
    private var attachedNotes: [SDAnnotation] {
        allAnnotations.filter { document.attachedNoteIDs.contains($0.id.uuidString) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Text("Pinned Research")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
            
            Divider()
            
            if attachedNotes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    Text("No pinned notes.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Use the Zettelkasten Hub to pin highlights to this chapter.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(attachedNotes) { note in
                            InspectorNoteCard(note: note)
                        }
                    }
                    .padding()
                }
            }
        }
        .background(Color(UIColor.systemGroupedBackground))
    }
}

struct InspectorNoteCard: View {
    let note: SDAnnotation
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(Color(hex: note.colorHex ?? "#FFD60A"))
                    .frame(width: 8, height: 8)
                Text(note.readwiseBookTitle ?? "Source Note")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            if let text = note.selectedText, !text.isEmpty {
                Text(text)
                    .font(.system(.caption, design: .serif))
                    .foregroundColor(.primary)
            }
            
            if let userNote = note.noteText, !userNote.isEmpty {
                HStack(alignment: .top) {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text(userNote)
                        .font(.caption)
                        .italic()
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
    }
}

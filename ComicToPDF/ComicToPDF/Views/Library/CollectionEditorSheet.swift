import SwiftUI

struct CollectionEditorSheet: View {
    @Environment(\.dismiss) var dismiss
    
    let isEditing: Bool
    let existingCollection: PDFCollection?
    let onSave: (String, String, String) -> Void
    
    @State private var name: String = ""
    @State private var selectedIcon: String = "folder.fill"
    @State private var selectedColor: String = "Blue"
    
    let icons = ["folder.fill", "book.fill", "books.vertical.fill", "tray.full.fill", "star.fill", "heart.fill", "bookmark.fill", "sparkles"]
    
    let colors = [
        ("Blue", Color.blue),
        ("Red", Color.red),
        ("Orange", Color.orange),
        ("Green", Color.green),
        ("Purple", Color.purple),
        ("Pink", Color.pink),
        ("Indigo", Color.indigo),
        ("Teal", Color.teal)
    ]
    
    init(existingCollection: PDFCollection? = nil, onSave: @escaping (String, String, String) -> Void) {
        self.isEditing = existingCollection != nil
        self.existingCollection = existingCollection
        self.onSave = onSave
        
        if let col = existingCollection {
            _name = State(initialValue: col.name)
            _selectedIcon = State(initialValue: col.icon)
            _selectedColor = State(initialValue: col.color)
        }
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Collection Name")) {
                    TextField("Name", text: $name)
                        .font(.headline)
                }
                
                Section(header: Text("Color")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(colors, id: \.0) { colorItem in
                                Circle()
                                    .fill(colorItem.1)
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.primary, lineWidth: selectedColor == colorItem.0 ? 3 : 0)
                                    )
                                    .onTapGesture {
                                        withAnimation {
                                            selectedColor = colorItem.0
                                        }
                                    }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                
                Section(header: Text("Icon")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 20) {
                        ForEach(icons, id: \.self) { icon in
                            Image(systemName: icon)
                                .font(.title2)
                                .frame(width: 50, height: 50)
                                .background(selectedIcon == icon ? colorFromName(selectedColor).opacity(0.2) : Color.clear)
                                .foregroundColor(selectedIcon == icon ? colorFromName(selectedColor) : .primary)
                                .cornerRadius(12)
                                .onTapGesture {
                                    withAnimation {
                                        selectedIcon = icon
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(isEditing ? "Edit Collection" : "New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, selectedIcon, selectedColor)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
    
    // Helper to map string to actual Color for previewing in the sheet
    private func colorFromName(_ name: String) -> Color {
        if let match = colors.first(where: { $0.0 == name }) {
            return match.1
        }
        return .blue
    }
}

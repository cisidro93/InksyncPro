import SwiftUI

// Uses the same GlassTextField and CustomGlassCard components defined in AdvancedMetadataEditorView.
// If they aren't globally available, we duplicate them here as private for safety in this scope, 
// or extract them to a shared file later. For now, we redefine them privately to guarantee compilation.

private struct CollectionGlassCard<Content: View>: View {
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
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    
                    // MARK: - Live Preview Header
                    VStack(spacing: 12) {
                        Image(systemName: selectedIcon)
                            .font(.system(size: 60))
                            .foregroundColor(colorFromName(selectedColor))
                            .shadow(color: colorFromName(selectedColor).opacity(0.5), radius: 10, x: 0, y: 5)
                            .padding(.top, 20)
                        
                        Text(name.isEmpty ? "New Collection" : name)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)
                    
                    // MARK: - Name Input
                    CollectionGlassCard(title: "Collection Name", icon: "pencil") {
                        TextField("Enter name...", text: $name)
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
                            )
                            .foregroundColor(.white)
                            .tint(colorFromName(selectedColor))
                    }
                    
                    // MARK: - Color Selection
                    CollectionGlassCard(title: "Theme Color", icon: "paintpalette.fill") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(colors, id: \.0) { colorItem in
                                    Circle()
                                        .fill(colorItem.1)
                                        .frame(width: 50, height: 50)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white, lineWidth: selectedColor == colorItem.0 ? 3 : 0)
                                        )
                                        .shadow(color: selectedColor == colorItem.0 ? colorItem.1.opacity(0.6) : .clear, radius: 8, y: 4)
                                        .scaleEffect(selectedColor == colorItem.0 ? 1.1 : 1.0)
                                        .onTapGesture {
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                                selectedColor = colorItem.0
                                            }
                                        }
                                }
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 4)
                        }
                    }
                    
                    // MARK: - Icon Selection
                    CollectionGlassCard(title: "Collection Icon", icon: "square.grid.2x2.fill") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 20) {
                            ForEach(icons, id: \.self) { icon in
                                ZStack {
                                    if selectedIcon == icon {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(colorFromName(selectedColor).opacity(0.2))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .stroke(colorFromName(selectedColor).opacity(0.5), lineWidth: 1)
                                            )
                                    }
                                    
                                    Image(systemName: icon)
                                        .font(.title)
                                        .foregroundColor(selectedIcon == icon ? colorFromName(selectedColor) : .white.opacity(0.7))
                                        .frame(width: 56, height: 56)
                                }
                                .scaleEffect(selectedIcon == icon ? 1.05 : 1.0)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                        selectedIcon = icon
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(isEditing ? "Edit Collection" : "New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Theme.textSecondary)
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, selectedIcon, selectedColor)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .fontWeight(.bold)
                    .foregroundColor(name.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.textSecondary : colorFromName(selectedColor))
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

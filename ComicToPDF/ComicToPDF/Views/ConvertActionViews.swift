import SwiftUI

// MARK: - Rename Before Convert Sheet (for Convert View)

struct RenameBeforeConvertSheet: View {
    @Environment(\.dismiss) private var dismiss
    let originalURL: URL
    @Binding var customNames: [URL: String]
    
    @State private var newName: String = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("File name", text: $newName)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: { Text("Output Name") } footer: { Text("This will be the name of the converted PDF file.") }
                
                Section {
                    HStack { Text("Original"); Spacer(); Text(originalURL.lastPathComponent).foregroundColor(.secondary).lineLimit(1) }
                    HStack { Text("Output"); Spacer(); Text("\(newName.isEmpty ? originalURL.deletingPathExtension().lastPathComponent : newName).pdf").foregroundColor(.orange).lineLimit(1) }
                } header: { Text("Preview") }
            }
            .navigationTitle("Rename Output").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        if !newName.isEmpty && newName != originalURL.deletingPathExtension().lastPathComponent {
                            customNames[originalURL] = newName
                        } else {
                            customNames.removeValue(forKey: originalURL)
                        }
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
            .onAppear { newName = customNames[originalURL] ?? originalURL.deletingPathExtension().lastPathComponent }
        }
    }
}

// MARK: - Updated File Row with Rename (for Convert View)

struct FileRowViewWithRename: View {
    let url: URL
    let customName: String?
    let onRename: () -> Void
    let onDelete: () -> Void
    
    var displayName: String { customName ?? url.deletingPathExtension().lastPathComponent }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: url.pathExtension.lowercased() == "cbr" ? "doc.zipper.fill" : "doc.zipper")
                .font(.title2).foregroundColor(.orange).frame(width: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).font(.subheadline).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 4) {
                    Text(url.pathExtension.uppercased()).font(.caption2).foregroundColor(.secondary).padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.2).cornerRadius(4))
                    if customName != nil { Text("renamed").font(.caption2).foregroundColor(.blue).padding(.horizontal, 6).padding(.vertical, 2).background(Color.blue.opacity(0.2).cornerRadius(4)) }
                }
            }
            
            Spacer()
            
            Button(action: onRename) { Image(systemName: "pencil.circle.fill").foregroundColor(.blue).font(.title2) }
            Button(action: onDelete) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}

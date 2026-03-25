import SwiftUI

struct StudyNotebookView: View {
    let bookID: String
    @StateObject private var store = StudyNotesStore.shared
    @Environment(\.colorScheme) var colorScheme
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "pencil.and.outline")
                    .foregroundColor(.inkBlue)
                    .font(.system(size: 14, weight: .semibold))
                Text("Study Notes")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.inkTextPrimary)
                Spacer()
                Button {
                    isFocused = false
                    store.saveNotes()
                } label: {
                    Text("Save")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isFocused ? .inkBlue : .inkTextSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.inkSurface.opacity(0.95))
            .overlay(Rectangle().frame(height: 1).foregroundColor(Color.inkSurfaceRaised), alignment: .bottom)
            
            // Editor
            TextEditor(text: Binding(
                get: { store.notes },
                set: { store.notes = $0; store.saveNotes() }
            ))
            .focused($isFocused)
            .padding(12)
            .font(.system(size: 15, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(Color.inkBackground)
        }
        .onAppear {
            store.loadNotes(for: bookID)
        }
    }
}

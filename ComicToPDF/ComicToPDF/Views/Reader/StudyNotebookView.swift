import SwiftUI

struct StudyNotebookView: View {
    let bookID: String
    @ObservedObject private var store = StudyNotesStore.shared
    @Environment(\.colorScheme) var colorScheme
    @FocusState private var isFocused: Bool
    
    @State private var localNotes: String = ""
    @State private var saveTask: Task<Void, Never>? = nil
    
    var body: some View {
        ZStack {
            // MARK: Premium Background Base
            Color(UIColor.systemBackground).ignoresSafeArea()
            
            VStack(spacing: 0) {
                // MARK: Glassmorphic Header
                HStack(spacing: 12) {
                    Image(systemName: "character.book.closed.fill")
                        .foregroundStyle(LinearGradient(colors: [Theme.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .font(.system(size: 18, weight: .bold))
                    
                    Text("Study Notebook")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if isFocused {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 8))
                            .foregroundColor(Theme.blue)
                            .symbolEffect(.pulse)
                        Text("Saving...")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                    } else {
                        Button {
                            isFocused = false
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(8)
                                .background(Color.primary.opacity(0.08))
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    Color(UIColor.systemBackground).opacity(0.85)
                        .background(.ultraThinMaterial)
                )
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.primary.opacity(0.05)), alignment: .bottom)
                
                // MARK: Debounced Editor Surface
                TextEditor(text: $localNotes)
                    .focused($isFocused)
                    .padding(16)
                    .font(.system(size: 16, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .foregroundColor(.primary)
                    .background(Color.clear)
                    .onChange(of: localNotes) { _, newText in
                        debounceSave(newText)
                    }
            }
        }
        .onAppear {
            store.loadNotes(for: bookID)
            localNotes = store.notes
        }
        .onDisappear {
            // Final explicit sync flush layer
            saveTask?.cancel()
            store.notes = localNotes
            store.saveNotes()
        }
    }
    
    // MARK: - Core Execution
    
    /// Throttles raw continuous SwiftUI text bindings to ensure `store.saveNotes()` disk flushes
    /// occur strictly at 1.0 second resting intervals, obliterating native Main Actor SSD amplification.
    private func debounceSave(_ text: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    store.notes = text
                    store.saveNotes()
                }
            }
        }
    }
}

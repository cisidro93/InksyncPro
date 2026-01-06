import SwiftUI

struct PanelEditorView: View {
    @State var session: PanelEditSession
    var onComplete: (PanelEditSession) -> Void
    var onCancel: () -> Void
    
    // UI State
    @State private var selectedPanelIndex: Int?
    
    var body: some View {
        NavigationView {
            VStack {
                // Main Editor Area
                ZStack {
                    Color.black.edgesIgnoringSafeArea(.all)
                    
                    if let image = session.originalImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .overlay(
                                GeometryReader { geo in
                                    ForEach(session.panels.indices, id: \.self) { index in
                                        let panel = session.panels[index]
                                        Rectangle()
                                            .path(in: rect(for: panel.boundingBox, in: geo.size))
                                            .stroke(selectedPanelIndex == index ? Color.yellow : Color.blue, lineWidth: 3)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                selectedPanelIndex = index
                                            }
                                    }
                                }
                            )
                    }
                }
                
                // Toolbar
                HStack {
                    Button(action: {
                        // Delete selected panel
                        if let index = selectedPanelIndex {
                            session.panels.remove(at: index)
                            selectedPanelIndex = nil
                        }
                    }) {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selectedPanelIndex == nil)
                    
                    Spacer()
                    
                    Button(action: {
                        // Reset to AI detection
                        Task {
                            // In a real app, re-run AI here. For now, we just clear.
                            session.panels.removeAll()
                        }
                    }) {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
            }
            .navigationTitle("Edit Panels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onCancel() // ✅ Fix: Closes the view
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onComplete(session) // ✅ Fix: Saves and closes
                    }
                }
            }
        }
    }
    
    // Helper: Convert normalized rect (0..1) to screen pixels
    func rect(for normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: normalized.minX * size.width,
            y: (1.0 - normalized.maxY) * size.height, // Flip Y for Vision coords
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }
}

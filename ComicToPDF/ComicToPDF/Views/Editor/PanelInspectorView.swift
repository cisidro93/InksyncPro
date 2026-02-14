
import SwiftUI

// MARK: - Inspector View

struct PanelInspectorView: View {
    @ObservedObject var editorState: PageEditorState
    
    var body: some View {
        Form {
            if let index = editorState.selectedPanelIndex, editorState.pageModel.panels.indices.contains(index) {
                // We use a Binding to the specific panel in the array
                // Since PageModel is a struct inside ObservableObject, we need to bind manually or use a proxy
                
                let panelBinding = Binding<NormalizedRect>(
                    get: { editorState.pageModel.panels[index] },
                    set: { newValue in
                        // Create a command for this? Or direct edit?
                        // For "Live" slider editing, thousands of commands are bad.
                        // Better: Direct edit during drag, Command on "Commit" (End Editing).
                        // For TextFields, onCommit is good.
                        // For now, let's update state directly for "Live" feel, but this breaks Undo.
                        // To support Undo properly, we need `Binding` that wraps `execute(.resize...)` or similar.
                        
                        // BUT: The requirement says "@Bindable to link... for instant updates".
                        // Standard approach: Direct SwiftData bind. But we are using `PageModel` struct (temporary state).
                        // We will update the model directly. User can Undo via the button which reverts the whole model state if we snapshotted it?
                        // Actually, our `PageEditorState` saves snapshots. If we modify `pageModel` directly, we need to manually push state to undo stack before modification starts?
                        // Complex.
                        
                        // Compromise: Update model directly. If user wants to undo a text field change, they might need to use the field's own undo?
                        // Or we trigger a snapshot when field editing begins.
                        
                        editorState.pageModel.panels[index] = newValue
                    }
                )
                
                Section(header: Text("Position & Size")) {
                    HStack {
                        Text("X")
                        TextField("X", value: panelBinding.x, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text("Y")
                        TextField("Y", value: panelBinding.y, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text("W")
                        TextField("Width", value: panelBinding.width, format: .number)
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text("H")
                        TextField("Height", value: panelBinding.height, format: .number)
                            .keyboardType(.decimalPad)
                    }
                }
                
                Section(header: Text("Smart Actions")) {
                   Button("Snap to Grid", action: {
                       // Logic to snap this specific panel
                   })
                   
                   Button("Delete Panel", role: .destructive) {
                       let rect = editorState.pageModel.panels[index]
                       editorState.execute(.removePanel(index: index, rect: rect))
                       editorState.selectedPanelIndex = nil
                   }
                }
            } else {
                // ✅ Empty State -> show Page Properties & Log
                Section(header: Text("Page \(editorState.pageModel.panels.count) Panels")) {
                    labeledContent("Total Panels", value: "\(editorState.pageModel.panels.count)")
                    labeledContent("Proposed", value: "\(editorState.pageModel.proposedPanels.count)")
                    labeledContent("Snap Guides", value: "\(editorState.snapGuides.count)")
                }
                
                Section(header: Text("Debug Log")) {
                    if editorState.debugLog.isEmpty {
                        Text("No events yet.")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
                        List {
                            ForEach(editorState.debugLog.reversed(), id: \.self) { log in
                                Text(log)
                                    .font(.caption2)
                                    .monospaced() // Code-like look for logs
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                }
                
                Section {
                    ContentUnavailableView(
                        "No Panel Selected",
                        systemImage: "square.dashed",
                        description: Text("Select a panel on the canvas to edit its layout.")
                    )
                }
            }
        }
    }
    
    @ViewBuilder
    func labeledContent(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}

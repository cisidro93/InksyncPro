import SwiftUI

struct PanelEditorView: View {
    let image: UIImage
    @Binding var panels: [CGRect]
    var onDone: ([CGRect]) -> Void
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedIndex: Int? = nil
    
    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                ZStack {
                    Color.black.edgesIgnoringSafeArea(.all)
                    
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            GeometryReader { imageReader in
                                Color.clear
                                    .onAppear {
                                        // Optional: capture image frame if needed
                                    }
                                    .overlay(
                                        ZStack {
                                            ForEach(panels.indices, id: \.self) { index in
                                                DraggableEditorPanel(
                                                    rect: $panels[index],
                                                    isSelected: selectedIndex == index,
                                                    containerSize: imageReader.size
                                                )
                                                .onTapGesture {
                                                    selectedIndex = index
                                                }
                                            }
                                        }
                                    )
                            }
                        )
                }
            }
            .navigationTitle("Edit Panels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if let _ = selectedIndex {
                        Button(role: .destructive) {
                            deleteSelected()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button("Add Panel") {
                            addPanel()
                        }
                        Button("Done") {
                            onDone(panels)
                            dismiss()
                        }
                        .bold()
                    }
                }
            }
        }
        // Ensure it only supports portrait or adapt properly
    }
    
    func deleteSelected() {
        guard let index = selectedIndex else { return }
        panels.remove(at: index)
        selectedIndex = nil
    }
    
    func addPanel() {
        panels.append(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        selectedIndex = panels.count - 1
    }
}

// MARK: - Box Component
struct DraggableEditorPanel: View {
    @Binding var rect: CGRect
    let isSelected: Bool
    let containerSize: CGSize
    
    @State private var initialRect: CGRect? = nil
    
    var centerPosition: CGPoint {
        let centerX = (rect.origin.x + rect.width / 2) * containerSize.width
        let centerY = (rect.origin.y + rect.height / 2) * containerSize.height
        return CGPoint(x: centerX, y: centerY)
    }
    
    var pixelSize: CGSize {
        CGSize(width: rect.width * containerSize.width, height: rect.height * containerSize.height)
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.blue.opacity(0.3)) // Semi-transparent blue
                .overlay(
                    Rectangle()
                        .stroke(isSelected ? Color.orange : Color.blue, lineWidth: isSelected ? 3 : 2)
                )
            
            if isSelected {
                Image(systemName: "arrow.up.left.and.arrow.down.right.circle.fill")
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.blue))
                    .font(.title2)
                    .position(x: pixelSize.width, y: pixelSize.height)
                    .gesture(
                        DragGesture(coordinateSpace: .local)
                            .onChanged { value in
                                if initialRect == nil { initialRect = rect }
                                guard let startRect = initialRect else { return }
                                
                                let dx = value.translation.width / containerSize.width
                                let dy = value.translation.height / containerSize.height
                                
                                rect.size.width = max(0.05, startRect.width + dx)
                                rect.size.height = max(0.05, startRect.height + dy)
                            }
                            .onEnded { _ in initialRect = nil }
                    )
            }
        }
        .frame(width: pixelSize.width, height: pixelSize.height)
        .position(centerPosition)
        .gesture(
            DragGesture(coordinateSpace: .local)
                .onChanged { value in
                    if isSelected {
                        if initialRect == nil { initialRect = rect }
                        guard let startRect = initialRect else { return }
                        
                        let dx = value.translation.width / containerSize.width
                        let dy = value.translation.height / containerSize.height
                        
                        let newX = startRect.origin.x + dx
                        let newY = startRect.origin.y + dy
                        
                        rect.origin.x = min(max(newX, 0.0), 1.0 - rect.width)
                        rect.origin.y = min(max(newY, 0.0), 1.0 - rect.height)
                    }
                }
                .onEnded { _ in initialRect = nil }
        )
    }
}

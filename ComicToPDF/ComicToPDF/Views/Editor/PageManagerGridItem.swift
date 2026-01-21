import SwiftUI

// Extracted Subview to fix Compiler Timeout
struct PageManagerGridItem: View {
    let item: GridPageItem
    let pdf: ConvertedPDF
    let isSelectionMode: Bool
    let isSelected: Bool
    @EnvironmentObject var conversionManager: ConversionManager
    
    // Bindings for Drag/Drop & Selection
    @Binding var items: [GridPageItem]
    @Binding var draggedItem: GridPageItem?
    var onToggleSelection: () -> Void
    var onEdit: (UIImage) -> Void
    
    var body: some View {
        VStack {
            SafeGridCell(url: item.url)
                .frame(height: 150)
                .cornerRadius(8)
                .overlay(
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
                        
                        if conversionManager.panelOverrides[pdf.id]?[item.index] != nil {
                            HStack(spacing: 2) {
                                Image(systemName: "wand.and.stars")
                                    .font(.caption2)
                                Text("Guided")
                                    .font(.caption2)
                                    .bold()
                            }
                            .padding(4)
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                            .padding(4)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                )
                .id(item.index)
                .onTapGesture {
                    if isSelectionMode || isSelected {
                        onToggleSelection()
                    } else {
                        if let image = UIImage(contentsOfFile: item.url.path) {
                            onEdit(image)
                        }
                    }
                }
                .onDrag {
                    self.draggedItem = item
                    return NSItemProvider(object: "\(item.index)" as NSString)
                }
                .onDrop(of: [.text], delegate: PageManagerDropDelegate(item: item, items: $items, draggedItem: $draggedItem))
            
            Text("\(item.index + 1)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// Renamed Delegate to avoid conflicts if any remain (though we fixed ReorderView)
struct PageManagerDropDelegate: DropDelegate {
    let item: GridPageItem
    @Binding var items: [GridPageItem]
    @Binding var draggedItem: GridPageItem?
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
    
    func performDrop(info: DropInfo) -> Bool {
        self.draggedItem = nil
        return true
    }
    
    func dropEntered(info: DropInfo) {
        guard let draggedItem = draggedItem else { return }
        guard let fromIndex = items.firstIndex(where: { $0.id == draggedItem.id }),
              let toIndex = items.firstIndex(where: { $0.id == item.id }) else { return }
        
        if fromIndex != toIndex {
            withAnimation {
                items.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            }
        }
    }
}

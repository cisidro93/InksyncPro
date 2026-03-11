import SwiftUI

/// A custom layout that flows views like text wrapping, used for the Tag Chips.
struct TagLayoutView: Layout {
    var spacing: CGFloat
    
    init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        
        for (index, subview) in subviews.enumerated() {
            let point = result.points[index]
            subview.place(at: CGPoint(x: point.x + bounds.minX, y: point.y + bounds.minY), proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var points: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if currentX + size.width > maxWidth, currentX > 0 {
                    // Move to next line
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                
                points.append(CGPoint(x: currentX, y: currentY))
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
            }
            
            self.size = CGSize(width: maxWidth, height: currentY + lineHeight)
            if self.size.height == 0 && !subviews.isEmpty {
                // Fallback for infinite width proposal
                self.size.height = subviews[0].sizeThatFits(.unspecified).height
            }
        }
    }
}

/// A view for adding and removing tags dynamically.
struct TagEditorView: View {
    @Binding var tags: [String]
    @State private var newTag: String = ""
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !tags.isEmpty {
                TagLayoutView(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        TagChip(tag: tag) {
                            withAnimation {
                                tags.removeAll(where: { $0 == tag })
                            }
                        }
                    }
                }
            } else {
                Text("No tags added.")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
                    .padding(.vertical, 4)
            }
            
            HStack {
                TextField("Add a tag...", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
                    .onSubmit {
                        addTag()
                    }
                
                Button(action: addTag) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .blue)
                }
                .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    
    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !tags.contains(tag) else {
            newTag = ""
            return
        }
        
        withAnimation {
            tags.append(tag)
        }
        newTag = ""
    }
}

struct TagChip: View {
    let tag: String
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.subheadline)
                .bold()
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.blue.opacity(0.15))
        .foregroundColor(.primary)
        .cornerRadius(16)
    }
}

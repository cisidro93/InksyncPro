import SwiftUI

// MARK: - Bear-Style Nested Tag Sidebar View

/// Collapsible hierarchical tree navigator for nested tags (e.g., `#medicine/neurology/synapses`).
public struct NestedTagSidebarView: View {
    let nodes: [NestedTagNode]
    @Binding var selectedTag: String?
    let totalCardsCount: Int
    
    public init(
        nodes: [NestedTagNode],
        selectedTag: Binding<String?>,
        totalCardsCount: Int
    ) {
        self.nodes = nodes
        self._selectedTag = selectedTag
        self.totalCardsCount = totalCardsCount
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: All Items Row
            Button {
                HapticEngine.selection()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    selectedTag = nil
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(selectedTag == nil ? .inkViolet : .inkTextSecondary)
                    
                    Text("All Knowledge")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(selectedTag == nil ? .inkTextPrimary : .inkTextSecondary)
                    
                    Spacer()
                    
                    Text("\(totalCardsCount)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.inkTextTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    selectedTag == nil
                        ? AnyShapeStyle(Color.inkViolet.opacity(0.12))
                        : AnyShapeStyle(Color.clear)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            
            // Section Header
            if !nodes.isEmpty {
                Text("NESTED TAGS")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.inkTextTertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }
            
            // Recursive Tag Tree Nodes
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(nodes) { node in
                        NestedTagRowView(node: node, selectedTag: $selectedTag, depth: 0)
                    }
                }
            }
        }
    }
}

// MARK: - Individual Recursive Node Row

public struct NestedTagRowView: View {
    let node: NestedTagNode
    @Binding var selectedTag: String?
    let depth: Int
    
    @State private var isExpanded: Bool = true
    
    public init(node: NestedTagNode, selectedTag: Binding<String?>, depth: Int = 0) {
        self.node = node
        self._selectedTag = selectedTag
        self.depth = depth
    }
    
    private var isSelected: Bool {
        selectedTag == node.fullPath
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                // Indentation Spacer
                if depth > 0 {
                    Spacer()
                        .frame(width: CGFloat(depth * 14))
                }
                
                // Expand / Collapse Chevron
                if !node.children.isEmpty {
                    Button {
                        HapticEngine.light()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.inkTextTertiary)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer()
                        .frame(width: 14)
                }
                
                // Tag Selection Button
                Button {
                    HapticEngine.selection()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        if selectedTag == node.fullPath {
                            selectedTag = nil // Toggle off
                        } else {
                            selectedTag = node.fullPath
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "number")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(isSelected ? .inkViolet : .inkTextSecondary)
                        
                        Text(node.name)
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                            .foregroundColor(isSelected ? .inkTextPrimary : .inkTextSecondary)
                            .lineLimit(1)
                        
                        Spacer()
                        
                        Text("\(node.cardCount)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(isSelected ? .inkViolet : .inkTextTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(isSelected ? 0.12 : 0.04), in: Capsule())
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(
                        isSelected
                            ? AnyShapeStyle(Color.inkViolet.opacity(0.12))
                            : AnyShapeStyle(Color.clear)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            
            // Sub-branches
            if isExpanded && !node.children.isEmpty {
                ForEach(node.children) { child in
                    NestedTagRowView(node: child, selectedTag: $selectedTag, depth: depth + 1)
                }
            }
        }
    }
}

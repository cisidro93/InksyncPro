import SwiftUI

struct WorkAreaToolbar: View {
    @Binding var selectedTool: ToolType
    @Binding var isProcessing: Bool
    var onScan: () -> Void
    var onCommit: () -> Void // For "Commit" action in AI workflow
    var canCommit: Bool
    
    enum ToolType: String, CaseIterable, Identifiable {
        case scan = "Scan"
        case edit = "Edit" // Standard selection/move
        case knife = "Knife"
        case anchor = "Anchor"
        case preview = "Preview"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .scan: return "sparkles"
            case .edit: return "cursorarrow.rays"
            case .knife: return "scissors"
            case .anchor: return "number.square"
            case .preview: return "eye"
            }
        }
    }
    
    var body: some View {
        HStack {
            ForEach(ToolType.allCases) { tool in
                Button {
                    if tool == .scan {
                        onScan() // Action button, doesn't switch state permanently? 
                        // Actually, scan might just be an action. 
                        // But let's select it to show active state if needed.
                        selectedTool = .edit // Reset to edit after scan?
                    } else {
                        selectedTool = tool
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tool.icon)
                            .font(.system(size: 24))
                        Text(tool.rawValue).font(.caption2)
                    }
                    .foregroundColor(selectedTool == tool ? .blue : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
            }
            
            // ✅ "Commit" Action for AI Suggestions
            if canCommit {
                Divider()
                
                Button(action: onCommit) {
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.green)
                        Text("Commit").font(.caption2).foregroundColor(.green)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 20) // Safe area
        .background(
            liquidGlassBackground()
        )
        .cornerRadius(20, corners: [.topLeft, .topRight])
        .shadow(radius: 5)
    }
    
    @ViewBuilder
    func liquidGlassBackground() -> some View {
        if #available(iOS 26.0, *) {
             // Hypothetical iOS 26 API
             // Generic "material" usage for now as placeholder for unknown API
             Rectangle().fill(.regularMaterial) 
        } else {
             // Fallback
             Rectangle().fill(.ultraThinMaterial)
        }
    }
}

// Helper for corner radius
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

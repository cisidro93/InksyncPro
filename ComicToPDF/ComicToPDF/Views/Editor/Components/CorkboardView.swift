import SwiftUI
import SwiftData

struct CorkboardView: View {
    @Bindable var project: SDManuscriptProject
    @Binding var selectedDocumentID: UUID?
    @Environment(\.modelContext) private var modelContext

    @State private var draggedDocument: SDManuscriptDocument?

    private var sortedDocuments: [SDManuscriptDocument] {
        project.documents.sorted(by: { $0.orderIndex < $1.orderIndex })
    }

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 20)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header details
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Drafting Board")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.inkTextPrimary)
                        Text("Drag index cards to rearrange binder order. Tap to write.")
                            .font(.caption)
                            .foregroundStyle(Color.inkTextSecondary)
                    }
                    Spacer()
                    
                    // Word count indicator
                    HStack(spacing: 8) {
                        Image(systemName: "pencil.and.outline")
                            .font(.caption)
                            .foregroundStyle(Color.inkAccentKnowledge)
                        Text("\(project.currentWordCount) / \(project.targetWordCount > 0 ? "\(project.targetWordCount)" : "10k") words")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.inkTextPrimary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.inkSurfaceRaised, in: Capsule())
                    .overlay(Capsule().stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                // Corkboard Grid
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(sortedDocuments) { doc in
                        CorkboardIndexCard(document: doc) {
                            selectedDocumentID = doc.id
                        }
                        .onDrag {
                            self.draggedDocument = doc
                            return NSItemProvider(object: doc.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: CorkboardDropDelegate(
                            target: doc,
                            dragged: $draggedDocument,
                            documents: sortedDocuments,
                            project: project,
                            modelContext: modelContext
                        ))
                    }
                }
                .padding(24)
            }
        }
        .background(
            ZStack {
                Color.inkBackground
                // Subtle cork/linen grid lines to look like a premium drafting board
                canvasBackground
            }
        )
    }

    private var canvasBackground: some View {
        Canvas { context, size in
            let step: CGFloat = 30
            var x: CGFloat = 0
            while x < size.width {
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                    },
                    with: .color(Color.primary.opacity(0.015)),
                    lineWidth: 0.5
                )
                x += step
            }
            var y: CGFloat = 0
            while y < size.height {
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: size.width, y: y))
                    },
                    with: .color(Color.primary.opacity(0.015)),
                    lineWidth: 0.5
                )
                y += step
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Corkboard Index Card
struct CorkboardIndexCard: View {
    let document: SDManuscriptDocument
    let onTap: () -> Void

    private var wordCount: Int { document.wordCount }
    private var targetWordCount: Int { 1000 } // standard default target per chapter

    private var progress: Double {
        min(1.0, Double(wordCount) / Double(targetWordCount))
    }

    private var status: (title: String, color: Color) {
        if wordCount == 0 {
            return ("Outline", Color.inkTextTertiary)
        } else if wordCount < 800 {
            return ("Drafting", Color.orange)
        } else {
            return ("Completed", Color.green)
        }
    }

    private var synopsis: String {
        let clean = document.contentMarkdown
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            return "No synopsis. Tap to start writing."
        }
        let lines = clean.components(separatedBy: .newlines)
        let firstNonEmpty = lines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        if firstNonEmpty.count > 120 {
            return String(firstNonEmpty.prefix(120)) + "..."
        }
        return firstNonEmpty
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                // Header (Red index card rule + word count progress)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.inkTextPrimary)
                            .lineLimit(1)
                        Text(status.title)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(status.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(status.color.opacity(0.12), in: Capsule())
                    }
                    Spacer()

                    // Circular Progress Ring
                    ZStack {
                        Circle()
                            .stroke(Color.inkBorderSubtle, lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(
                                progress >= 1.0 ? Color.green : Color.inkAccentKnowledge,
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.inkTextSecondary)
                    }
                    .frame(width: 28, height: 28)
                }

                Divider()
                    .background(Color.inkBorderSubtle)

                // Synopsis/Draft Extract
                Text(synopsis)
                    .font(.system(size: 12, design: .serif))
                    .lineSpacing(4)
                    .italic(wordCount == 0)
                    .foregroundStyle(wordCount == 0 ? Color.inkTextTertiary : Color.inkTextSecondary)
                    .frame(height: 60, alignment: .topLeading)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                // Card Footer
                HStack {
                    Text("\(wordCount) words")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.inkTextTertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Color.inkTextTertiary)
                }
            }
            .padding(16)
            .frame(height: 170)
            .background(Color.inkSurfaceRaised)
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.05), radius: 6, y: 3)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.inkBorderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Corkboard Drop Delegate
struct CorkboardDropDelegate: DropDelegate {
    let target: SDManuscriptDocument
    @Binding var dragged: SDManuscriptDocument?
    let documents: [SDManuscriptDocument]
    let project: SDManuscriptProject
    let modelContext: ModelContext

    func performDrop(info: DropInfo) -> Bool {
        guard let dragged = dragged, dragged.id != target.id else { return false }
        
        let targetIndex = target.orderIndex
        var newDocuments = documents
        
        // Remove dragged
        if let sourceIdx = newDocuments.firstIndex(where: { $0.id == dragged.id }) {
            newDocuments.remove(at: sourceIdx)
        }
        
        // Insert dragged at target index
        if let targetIdx = newDocuments.firstIndex(where: { $0.id == target.id }) {
            newDocuments.insert(dragged, at: targetIdx)
        }
        
        // Re-assign order indices
        for (index, doc) in newDocuments.enumerated() {
            doc.orderIndex = index
        }
        
        try? modelContext.save()
        self.dragged = nil
        return true
    }
}

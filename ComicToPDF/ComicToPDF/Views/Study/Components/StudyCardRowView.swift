import SwiftUI

// MARK: - Study Card Row View

/// Premium glassmorphic card cell displaying cloze teasers, passage citations, Adler markers, and SRS due badges.
public struct StudyCardRowView: View {
    let card: StudyCard
    var onSelect: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    
    @Environment(\.colorScheme) private var colorScheme
    private let clozeParser = ClozeDeletionParser.shared
    
    public init(
        card: StudyCard,
        onSelect: (() -> Void)? = nil,
        onEdit: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.card = card
        self.onSelect = onSelect
        self.onEdit = onEdit
        self.onDelete = onDelete
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // MARK: - Card Header (Adler Marker & Due Status)
            HStack(spacing: 8) {
                if let marker = card.adlerTag {
                    HStack(spacing: 4) {
                        Text(marker.symbol)
                            .font(.system(size: 11, weight: .black, design: .rounded))
                        Text(marker.title)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(marker.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(marker.accentColor.opacity(0.12), in: Capsule())
                }
                
                Spacer()
                
                // Due Date Badge
                HStack(spacing: 3) {
                    Image(systemName: card.isDue ? "clock.badge.exclamationmark.fill" : "clock")
                        .font(.system(size: 9, weight: .bold))
                    Text(dueStatusText)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .foregroundColor(card.isDue ? .inkRed : .inkTextTertiary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    card.isDue
                        ? Color.inkRed.opacity(0.12)
                        : Color.primary.opacity(0.04),
                    in: Capsule()
                )
            }
            
            // MARK: - Card Markdown Body (with Cloze Highlighting)
            clozeRenderedBody
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundColor(.inkTextPrimary)
                .lineSpacing(3)
                .lineLimit(4)
            
            // MARK: - Passage Citation Deep Link
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.inkViolet)
                
                Text(card.citation.documentTitle)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.inkTextPrimary)
                    .lineLimit(1)
                
                Text("•  p. \(card.citation.pageNumber)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.inkTextSecondary)
                
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            
            // MARK: - Tags & SRS Metadata
            HStack(spacing: 6) {
                ForEach(card.tags.prefix(3), id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.inkViolet)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.inkViolet.opacity(0.08), in: Capsule())
                }
                
                if card.tags.count > 3 {
                    Text("+\(card.tags.count - 3)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.inkTextTertiary)
                }
                
                Spacer()
                
                Text("Reps: \(card.repetitionCount) • EF: \(String(format: "%.1f", card.easeFactor))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.inkTextTertiary)
            }
        }
        .padding(14)
        .background(
            Color.inkSurface
                .background(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?()
        }
        .contextMenu {
            if let onEdit = onEdit {
                Button { onEdit() } label: {
                    Label("Edit Card", systemImage: "pencil")
                }
            }
            if let onDelete = onDelete {
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete Card", systemImage: "trash")
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private var dueStatusText: String {
        if card.isDue {
            return "Due Today"
        }
        let diff = Calendar.current.dateComponents([.day], from: Date(), to: card.dueDate).day ?? 0
        if diff <= 1 {
            return "Due Tomorrow"
        } else {
            return "Due in \(diff)d"
        }
    }
    
    @ViewBuilder
    private var clozeRenderedBody: some View {
        let segments = clozeParser.parseSegments(from: card.markdownBody)
        
        Text(segments.reduce(into: AttributedString()) { attr, segment in
            var part = AttributedString(segment.text)
            if segment.isCloze {
                part.backgroundColor = UIColor.systemPurple.withAlphaComponent(0.2)
                part.foregroundColor = UIColor.systemPurple
                part.font = .systemFont(ofSize: 14, weight: .bold)
            }
            attr.append(part)
        })
    }
}

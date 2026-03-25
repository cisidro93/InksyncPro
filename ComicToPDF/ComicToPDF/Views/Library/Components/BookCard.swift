import SwiftUI

struct BookCard: View {
    let pdf: ConvertedPDF
    let manager: ConversionManager
    let isSelected: Bool
    let isBatchMode: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onContextAction: (BookCardAction) -> Void

    @State private var coverImage: UIImage? = nil
    
    // Configurable width for non-grid contexts. If nil, expands to fill container.
    var fixedWidth: CGFloat? = 88
    private let coverAspectRatio: CGFloat = 0.66

    var statusBadge: (label: String, color: Color)? {
        if pdf.lastTransferFailed { return ("Failed", .inkRed) }
        if (pdf.panelConfidenceScore ?? 1.0) < 0.75 { return ("Review", .inkAmber) }
        if pdf.isOnDevice { return ("On Device", .inkGreen) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                // Cover
                Group {
                    if let img = coverImage {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color.inkSurfaceRaised)
                            .overlay(
                                Image(systemName: "book.closed.fill")
                                    .foregroundColor(.inkTextTertiary)
                                    .font(.system(size: 24))
                            )
                    }
                }
                .aspectRatio(coverAspectRatio, contentMode: .fit)
                .frame(width: fixedWidth)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.inkBorderVisible, lineWidth: 0.5)
                )

                // Status badge
                if let badge = statusBadge {
                    Text(badge.label)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(badge.color)
                        .clipShape(Capsule())
                        .padding(5)
                }

                // Batch selection overlay
                if isBatchMode {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.inkBlue.opacity(isSelected ? 0.4 : 0.0))
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.inkBlue)
                            .font(.system(size: 20))
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .topTrailing)
                    }
                }
            }

            // Title
            Text(pdf.metadata.title.isEmpty ? pdf.name : pdf.metadata.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.inkTextPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Volume / issue if available
            if let vol = pdf.metadata.volume, !vol.isEmpty {
                Text("Vol. \(vol)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.inkTextSecondary)
            }
        }
        .frame(width: fixedWidth)
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.5, perform: onLongPress)
        .contextMenu {
            Button("Convert & Send") { onContextAction(.send) }
            Button("Edit Metadata") { onContextAction(.editMetadata) }
            Button("Search Comic Vine") { onContextAction(.searchComicVine) }
            Button("Review Panels") { onContextAction(.reviewPanels) }
            Divider()
            Button("Delete", role: .destructive) { onContextAction(.delete) }
        }
        .task {
            coverImage = await manager.loadCoverThumbnail(for: pdf)
        }
    }
}

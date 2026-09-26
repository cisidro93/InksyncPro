import SwiftUI

// MARK: - Interactive Flow Page Flag Strip
// Synthesized from NeoFlow & Kavsoft ProMotion Polish.
// Provides rapid, non-blocking horizontal page flag scrubbing with active selection,
// category filtering ("Flagged Only" vs "All Pages"), and 120Hz ProMotion spring animations.

public struct PageFlagStrip: View {
    public let flaggedIndices: [Int]
    public let totalPages: Int
    public var selectedPageIndex: Int?
    public var onSelectPage: ((Int) -> Void)?

    @State private var filterFlaggedOnly: Bool = false
    @Namespace private var flagAnimationNamespace

    public init(
        flaggedIndices: [Int],
        totalPages: Int,
        selectedPageIndex: Int? = nil,
        onSelectPage: ((Int) -> Void)? = nil
    ) {
        self.flaggedIndices = flaggedIndices
        self.totalPages = max(0, totalPages)
        self.selectedPageIndex = selectedPageIndex
        self.onSelectPage = onSelectPage
        // Default to flagged-only filter if total pages is large to prevent horizontal bloat
        self._filterFlaggedOnly = State(initialValue: !flaggedIndices.isEmpty && totalPages > 25)
    }

    private var displayedIndices: [Int] {
        if filterFlaggedOnly && !flaggedIndices.isEmpty {
            return flaggedIndices.filter { $0 >= 0 && $0 < totalPages }.sorted()
        } else {
            return Array(0..<totalPages)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // MARK: - Header Bar
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.inkAmber)
                    Text("Flow Flags & Markers")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.inkTextPrimary)
                }

                Spacer()

                if !flaggedIndices.isEmpty {
                    // Filter Toggle Chip
                    Button {
                        HapticEngine.selection()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            filterFlaggedOnly.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: filterFlaggedOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                                .font(.system(size: 11, weight: .semibold))
                            Text(filterFlaggedOnly ? "Flagged (\(flaggedIndices.count))" : "All (\(totalPages))")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(filterFlaggedOnly ? .inkAmber : .inkTextSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            filterFlaggedOnly
                                ? Color.inkAmber.opacity(0.15)
                                : Color.inkSurfaceRaised,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .stroke(filterFlaggedOnly ? Color.inkAmber.opacity(0.4) : Color.inkBorderSubtle, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("\(totalPages) pages")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.inkTextTertiary)
                }
            }

            // MARK: - Horizontal Page Strip
            if displayedIndices.isEmpty {
                emptyFlaggedState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 6) {
                            ForEach(displayedIndices, id: \.self) { index in
                                let isFlagged = flaggedIndices.contains(index)
                                let isSelected = (selectedPageIndex == index)

                                PageFlagCard(
                                    pageIndex: index,
                                    isFlagged: isFlagged,
                                    isSelected: isSelected
                                ) {
                                    HapticEngine.light()
                                    onSelectPage?(index)
                                }
                                .id(index)
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                    }
                    .onAppear {
                        if let selected = selectedPageIndex {
                            proxy.scrollTo(selected, anchor: .center)
                        }
                    }
                    .onChange(of: selectedPageIndex) { _, newIndex in
                        if let newIndex {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                proxy.scrollTo(newIndex, anchor: .center)
                            }
                        }
                    }
                }
            }

            // MARK: - Subtitle / Context Hint
            if onSelectPage != nil {
                HStack(spacing: 4) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 9))
                    Text("Tap any flagged page to jump instantly · In-flow flags keep your reading rhythm")
                        .font(.system(size: 10))
                }
                .foregroundColor(.inkTextTertiary)
                .padding(.top, 2)
            } else {
                Text("Tap a highlighted page to review · or skip to use auto-detected panels")
                    .font(.system(size: 10))
                    .foregroundColor(.inkTextTertiary)
            }
        }
    }

    private var emptyFlaggedState: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Image(systemName: "flag.slash")
                    .font(.system(size: 16))
                    .foregroundColor(.inkTextTertiary)
                Text("No flagged pages in this chapter.")
                    .font(.system(size: 11))
                    .foregroundColor(.inkTextTertiary)
            }
            .padding(.vertical, 12)
            Spacer()
        }
        .background(Color.inkSurfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Page Flag Card (Miniature ProMotion Page Tile)
private struct PageFlagCard: View {
    let pageIndex: Int
    let isFlagged: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(cardBorderColor, lineWidth: isSelected ? 2.0 : (isFlagged ? 1.2 : 0.6))
                    )

                VStack(spacing: 3) {
                    Spacer()

                    // Miniature lines simulating text/art
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(lineColor.opacity(0.6))
                            .frame(width: 18, height: 2)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(lineColor.opacity(0.4))
                            .frame(width: 22, height: 2)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(lineColor.opacity(0.3))
                            .frame(width: 14, height: 2)
                    }

                    Spacer()

                    // Page number badge
                    Text("\(pageIndex + 1)")
                        .font(.system(size: 9, weight: isSelected ? .bold : .medium, design: .rounded))
                        .foregroundColor(isSelected ? .white : (isFlagged ? .inkAmber : .inkTextSecondary))
                        .lineLimit(1)
                        .padding(.bottom, 3)
                }
                .frame(maxWidth: .infinity)

                // Top corner flag tag
                if isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 7, weight: .black))
                        .foregroundColor(.inkAmber)
                        .padding(3)
                        .background(Color.inkAmber.opacity(0.2), in: Circle())
                        .offset(x: -2, y: 2)
                }
            }
            .frame(width: 36, height: 50)
            .scaleEffect(isSelected ? 1.06 : 1.0)
            .shadow(color: isSelected ? Color.inkAmber.opacity(0.3) : .clear, radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: Color {
        if isSelected {
            return Color.inkAmber.opacity(0.35)
        } else if isFlagged {
            return Color.inkAmber.opacity(0.18)
        } else {
            return Color.inkSurfaceRaised
        }
    }

    private var cardBorderColor: Color {
        if isSelected {
            return Color.inkAmber
        } else if isFlagged {
            return Color.inkAmber.opacity(0.7)
        } else {
            return Color.inkBorderSubtle
        }
    }

    private var lineColor: Color {
        if isFlagged || isSelected {
            return Color.inkAmber
        } else {
            return Color.inkTextTertiary
        }
    }
}

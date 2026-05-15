import SwiftUI
import SwiftData

// MARK: - Corkboard Canvas View

struct ZettelkastenCorkboardView: View {
    let annotations: [SDAnnotation]
    let pdfs: [SDConvertedPDF]

    @Environment(\.modelContext) private var modelContext

    // ── Canvas transform state ──────────────────────────────────────────────
    @State private var canvasScale: CGFloat = 1.0
    @State private var canvasOffset: CGSize = .zero

    /// Live drag delta — applied during gesture, merged into `canvasOffset` on end
    @State private var livePanDelta: CGSize = .zero
    @State private var livePinchScale: CGFloat = 1.0

    // ── Card lift state (in-memory only, persisted on gesture end) ──────────
    @State private var cardDragOffsets: [UUID: CGSize] = [:]
    @State private var liftedCardID: UUID? = nil

    // ── Layout & UI ─────────────────────────────────────────────────────────
    @State private var hasInitialized = false
    @State private var isAutoArranging = false

    private let minScale: CGFloat = 0.25
    private let maxScale: CGFloat = 2.5
    private let cardW: CGFloat = 270
    private let cardH: CGFloat = 200
    private let gridGap: CGFloat = 36

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // ── Background ──────────────────────────────────────────────
                DotGridBackground()
                    .ignoresSafeArea()

                // ── Infinite canvas ─────────────────────────────────────────
                infiniteCanvas
                    .scaleEffect(canvasScale * livePinchScale)
                    .offset(
                        x: canvasOffset.width + livePanDelta.width,
                        y: canvasOffset.height + livePanDelta.height
                    )
                    // Canvas pan — only fires when no card is being dragged
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { v in
                                guard liftedCardID == nil else { return }
                                livePanDelta = v.translation
                            }
                            .onEnded { v in
                                guard liftedCardID == nil else { return }
                                canvasOffset.width  += v.translation.width
                                canvasOffset.height += v.translation.height
                                livePanDelta = .zero
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { mag in
                                livePinchScale = mag
                            }
                            .onEnded { mag in
                                canvasScale = clampedScale(canvasScale * mag)
                                livePinchScale = 1.0
                            }
                    )

                // ── Bottom toolbar ──────────────────────────────────────────
                bottomToolbar(geo: geo)
            }
            .task {
                await initializePositionsIfNeeded(in: geo.size)
            }
        }
    }

    // MARK: - Infinite Canvas

    private var infiniteCanvas: some View {
        ZStack {
            // Invisible oversized hit area so gestures register on empty space
            Color.clear
                .frame(width: 6000, height: 6000)

            ForEach(annotations) { ann in
                let liveOffset = cardDragOffsets[ann.id] ?? .zero
                let baseX = CGFloat(ann.corkboardX ?? 0)
                let baseY = CGFloat(ann.corkboardY ?? 0)
                let isLifted = liftedCardID == ann.id

                IndexCardView(
                    annotation: ann,
                    pdfs: pdfs,
                    isLifted: isLifted,
                    onDelete: { removeFromCorkboard(ann) }
                )
                .position(
                    x: baseX + liveOffset.width,
                    y: baseY + liveOffset.height
                )
                .zIndex(isLifted ? 100 : 0)
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { v in
                            if liftedCardID != ann.id {
                                liftedCardID = ann.id
                                HapticEngine.selection()
                            }
                            cardDragOffsets[ann.id] = v.translation
                        }
                        .onEnded { v in
                            // Merge live offset into persisted position
                            ann.corkboardX = Double(baseX + v.translation.width)
                            ann.corkboardY = Double(baseY + v.translation.height)
                            cardDragOffsets.removeValue(forKey: ann.id)
                            liftedCardID = nil
                            try? modelContext.save()
                        }
                )
            }
        }
    }

    // MARK: - Bottom Toolbar

    private func bottomToolbar(geo: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            // Zoom out
            toolbarButton(icon: "minus", label: "Zoom Out") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    canvasScale = clampedScale(canvasScale - 0.25)
                }
            }
            // Scale indicator
            Text("\(Int(canvasScale * 100))%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.inkTextSecondary)
                .frame(width: 46)
                .onTapGesture {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        canvasScale = 1.0
                        livePinchScale = 1.0
                    }
                }
            // Zoom in
            toolbarButton(icon: "plus", label: "Zoom In") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    canvasScale = clampedScale(canvasScale + 0.25)
                }
            }

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 8)

            // Center canvas
            toolbarButton(icon: "scope", label: "Center") {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                    canvasOffset = .zero
                    livePanDelta  = .zero
                }
            }

            // Auto-arrange
            toolbarButton(icon: "rectangle.grid.3x2", label: "Arrange") {
                autoArrange(in: geo.size)
            }
            .disabled(isAutoArranging)

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 8)

            // Card count
            HStack(spacing: 4) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 11))
                Text("\(annotations.count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Color.inkTextSecondary)
            .padding(.trailing, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func toolbarButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
            }
            .frame(width: 40, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(CorkboardToolbarButtonStyle())
    }

    // MARK: - Auto-Arrange

    private func autoArrange(in size: CGSize) {
        guard !isAutoArranging else { return }
        isAutoArranging = true
        HapticEngine.selection()

        let cols = max(1, Int(sqrt(Double(annotations.count) * 1.4)))
        let hSpace = cardW + gridGap
        let vSpace = cardH + gridGap

        withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
            for (i, ann) in annotations.enumerated() {
                let col = i % cols
                let row = i / cols
                ann.corkboardX = Double(CGFloat(col) * hSpace + cardW / 2 + gridGap)
                ann.corkboardY = Double(CGFloat(row) * vSpace + cardH / 2 + gridGap)
            }
            // Reset view to show arranged cards
            canvasOffset = .zero
            canvasScale = 1.0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            try? modelContext.save()
            isAutoArranging = false
        }
    }

    // MARK: - Helpers

    private func removeFromCorkboard(_ ann: SDAnnotation) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            ann.corkboardX = nil
            ann.corkboardY = nil
        }
        try? modelContext.save()
    }

    private func clampedScale(_ s: CGFloat) -> CGFloat {
        max(minScale, min(s, maxScale))
    }

    @MainActor
    private func initializePositionsIfNeeded(in size: CGSize) async {
        guard !hasInitialized else { return }
        hasInitialized = true

        var didChange = false
        var col = 0
        var row = 0
        let cols = max(1, Int(size.width / (cardW + gridGap)))

        for ann in annotations where ann.corkboardX == nil || ann.corkboardY == nil {
            // Small jitter for organic feel
            let jitterX = CGFloat.random(in: -12...12)
            let jitterY = CGFloat.random(in: -12...12)
            ann.corkboardX = Double(CGFloat(col) * (cardW + gridGap) + cardW / 2 + gridGap + jitterX)
            ann.corkboardY = Double(CGFloat(row) * (cardH + gridGap) + cardH / 2 + gridGap + jitterY)
            didChange = true
            col += 1
            if col >= cols {
                col = 0
                row += 1
            }
        }

        if didChange {
            try? modelContext.save()
        }
    }
}

// MARK: - Dot Grid Background

struct DotGridBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let bg: Color = colorScheme == .dark
            ? Color(red: 0.054, green: 0.054, blue: 0.070)
            : Color(red: 0.961, green: 0.941, blue: 0.918)
        let dot: Color = colorScheme == .dark
            ? Color(red: 0.118, green: 0.118, blue: 0.157)
            : Color(red: 0.851, green: 0.788, blue: 0.714)

        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bg))
            let spacing: CGFloat = 28
            let r: CGFloat = 1.5
            var x: CGFloat = spacing / 2
            while x < size.width {
                var y: CGFloat = spacing / 2
                while y < size.height {
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .color(dot)
                    )
                    y += spacing
                }
                x += spacing
            }
        }
    }
}

// MARK: - Index Card

struct IndexCardView: View {
    @Bindable var annotation: SDAnnotation
    let pdfs: [SDConvertedPDF]
    var isLifted: Bool = false
    var onDelete: () -> Void

    @State private var showingEditNote = false
    @State private var editNoteText: String = ""

    private var bookTitle: String {
        pdfs.first(where: { $0.id == annotation.pdfID })?.name
            ?? annotation.readwiseBookTitle
            ?? "Unknown Source"
    }

    private var accentColor: Color {
        Color(hex: annotation.colorHex ?? "#8b5cf6")
    }

    private var kindIcon: String {
        switch annotation.kindRaw {
        case "note":     return "pencil.and.outline"
        case "bookmark": return "bookmark.fill"
        case "ink":      return "scribble"
        default:         return "highlighter"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // ── Left accent strip ───────────────────────────────────────────
            RoundedRectangle(cornerRadius: 3)
                .fill(accentColor)
                .frame(width: 4)
                .padding(.vertical, 10)
                .padding(.leading, 10)

            // ── Card content ────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 6) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(accentColor.opacity(0.8))
                    Text(bookTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.inkTextSecondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: kindIcon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(accentColor.opacity(0.7))
                }
                .padding(.top, 12)
                .padding(.horizontal, 12)

                // Divider line (index card style)
                Rectangle()
                    .fill(accentColor.opacity(0.25))
                    .frame(height: 0.8)
                    .padding(.top, 6)

                // Highlight text
                if let text = annotation.selectedText, !text.isEmpty {
                    Text(text)
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(Color.inkTextPrimary)
                        .lineLimit(5)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                // User note
                if let note = annotation.noteText, !note.isEmpty {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "pencil.line")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(accentColor.opacity(0.8))
                            .padding(.top, 2)
                        Text(note)
                            .font(.system(size: 12, design: .rounded))
                            .italic()
                            .foregroundStyle(Color.inkTextSecondary)
                            .lineLimit(3)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                }

                Spacer(minLength: 6)

                // Tag chips
                if let tags = annotation.tags, !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(tags.prefix(4), id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(accentColor.opacity(0.12), in: Capsule())
                            }
                            if tags.count > 4 {
                                Text("+\(tags.count - 4)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.inkTextTertiary)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(width: 270)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.inkSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accentColor.opacity(isLifted ? 0.08 : 0.04))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    accentColor.opacity(isLifted ? 0.45 : 0.18),
                    lineWidth: isLifted ? 1.5 : 0.8
                )
        )
        .shadow(
            color: isLifted
                ? accentColor.opacity(0.35)
                : Color.black.opacity(0.15),
            radius: isLifted ? 22 : 8,
            y: isLifted ? 10 : 4
        )
        .scaleEffect(isLifted ? 1.04 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isLifted)
        // Context Menu
        .contextMenu {
            Button {
                editNoteText = annotation.noteText ?? ""
                showingEditNote = true
            } label: {
                Label("Edit Note", systemImage: "pencil.line")
            }

            Button {
                let text = [annotation.selectedText, annotation.noteText]
                    .compactMap { $0 }
                    .joined(separator: "\n\n")
                UIPasteboard.general.string = text
                HapticEngine.selection()
            } label: {
                Label("Copy Text", systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
                HapticEngine.medium()
            } label: {
                Label("Remove from Corkboard", systemImage: "xmark.circle")
            }
        }
        .sheet(isPresented: $showingEditNote) {
            editNoteSheet
        }
    }

    // MARK: - Edit Note Sheet

    private var editNoteSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                if let text = annotation.selectedText, !text.isEmpty {
                    Text(text)
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(Color.inkTextSecondary)
                        .padding()
                        .background(accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                TextEditor(text: $editNoteText)
                    .font(.system(.body, design: .rounded))
                    .scrollContentBackground(.hidden)
                    .background(Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                    .frame(minHeight: 120)
            }
            .padding()
            .background(Color.inkBackground.ignoresSafeArea())
            .navigationTitle("Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingEditNote = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        annotation.noteText = editNoteText.isEmpty ? nil : editNoteText
                        annotation.modifiedAt = Date()
                        showingEditNote = false
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.inkAccentKnowledge)
                }
            }
        }
    }
}

// MARK: - Toolbar Button Style

struct CorkboardToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                configuration.isPressed
                    ? Color.inkAccentKnowledge
                    : Color.inkTextSecondary
            )
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

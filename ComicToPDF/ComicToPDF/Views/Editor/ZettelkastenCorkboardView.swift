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
    @State private var liftedCardID: UUID? = nil

    // ── Layout & UI ─────────────────────────────────────────────────────────
    @State private var hasInitialized = false
    @State private var isAutoArranging = false
    
    // ── Organization ────────────────────────────────────────────────────────
    @State private var corkboardGroupByTag: Bool = false
    @State private var activeCorkboardTags: Set<String> = []
    
    private var allAvailableTags: [String] {
        let all = annotations.compactMap { $0.tags }.flatMap { $0 } + 
                  annotations.compactMap { $0.readwiseTags }.flatMap { $0 } +
                  annotations.compactMap { $0.readwiseDocumentTags }.flatMap { $0 }
        return Array(Set(all)).sorted()
    }
    
    private func matchesActiveTags(_ ann: SDAnnotation) -> Bool {
        if activeCorkboardTags.isEmpty { return true }
        let annTags = Set((ann.tags ?? []) + (ann.readwiseTags ?? []) + (ann.readwiseDocumentTags ?? []))
        return !activeCorkboardTags.isDisjoint(with: annTags)
    }

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
                infiniteCanvas(panGesture: canvasPanGesture)
                    .scaleEffect(canvasScale * livePinchScale)
                    .offset(
                        x: canvasOffset.width + livePanDelta.width,
                        y: canvasOffset.height + livePanDelta.height
                    )
                    // Pinch lives at ZStack level so two-finger gestures work
                    // anywhere on screen, not just over empty canvas space.
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { mag in livePinchScale = mag }
                            .onEnded   { mag in
                                canvasScale = clampedScale(canvasScale * mag)
                                livePinchScale = 1.0
                            }
                    )

                // ── Filter HUD ──────────────────────────────────────────────
                if !allAvailableTags.isEmpty {
                    tagFilterHUD()
                        .padding(.bottom, 80)
                }

                // ── Bottom toolbar ──────────────────────────────────────────
                bottomToolbar(geo: geo)
            }
            .clipped()
            .task {
                await initializePositionsIfNeeded(in: geo.size)
            }
        }
    }

    // The pan gesture is defined here so we can attach it directly to the
    // background hit-area inside infiniteCanvas, NOT to the parent ZStack.
    // SwiftUI resolves gestures child-before-parent, so attaching pan only
    // to the background means card drags always win when a card is touched,
    // and panning fires reliably on any empty space — no conflicts.
    private var canvasPanGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                livePanDelta = v.translation
            }
            .onEnded { v in
                canvasOffset.width  += v.translation.width
                canvasOffset.height += v.translation.height
                livePanDelta = .zero
            }
    }

    // MARK: - Infinite Canvas

    private func infiniteCanvas(panGesture: some Gesture) -> some View {
        ZStack {
            // Pan gesture lives ONLY on this background slab.
            // Touches on cards fall through to the card's own DragGesture.
            Color.clear
                .frame(width: 6000, height: 6000)
                .contentShape(Rectangle())   // make clear fully hittable
                .gesture(panGesture)

            if corkboardGroupByTag {
                SwimLaneBackgrounds(annotations: annotations, cardW: cardW, cardH: cardH, gridGap: gridGap)
            }

            ForEach(annotations) { ann in
                IndexCardCanvasWrapperView(
                    annotation: ann,
                    pdfs: pdfs,
                    liftedCardID: $liftedCardID,
                    matchesActiveTags: matchesActiveTags(ann),
                    cardW: cardW,
                    cardH: cardH,
                    onDelete: { removeFromCorkboard(ann) },
                    onSave: { try? modelContext.save() }
                )
            }
        }
    }
    
    // MARK: - Tag Filter HUD
    private func tagFilterHUD() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !activeCorkboardTags.isEmpty {
                    Button("Clear") {
                        withAnimation(.spring()) { activeCorkboardTags.removeAll() }
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red, in: Capsule())
                }
                
                ForEach(allAvailableTags, id: \.self) { tag in
                    let isActive = activeCorkboardTags.contains(tag)
                    Button {
                        withAnimation(.spring()) {
                            if isActive {
                                activeCorkboardTags.remove(tag)
                            } else {
                                activeCorkboardTags.insert(tag)
                            }
                        }
                    } label: {
                        Text("#\(tag)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(isActive ? .white : Theme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(isActive ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                            .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
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

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 8)
                
            // Group By Tag
            toolbarButton(icon: corkboardGroupByTag ? "tag.fill" : "tag", label: "By Tag") {
                withAnimation(.spring()) {
                    corkboardGroupByTag.toggle()
                }
                autoArrange(in: geo.size)
            }
            .foregroundColor(corkboardGroupByTag ? .orange : .primary)

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

        var targetPositions: [UUID: (x: Double, y: Double)] = [:]

        if corkboardGroupByTag {
            var yOffset: CGFloat = gridGap
            var dict: [String: [SDAnnotation]] = [:]
            for ann in annotations {
                let tags = (ann.tags ?? []) + (ann.readwiseTags ?? []) + (ann.readwiseDocumentTags ?? [])
                let primaryTag = tags.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "Untagged"
                dict[primaryTag, default: []].append(ann)
            }
            
            let sortedKeys = dict.keys.sorted {
                if $0 == "Untagged" { return false }
                if $1 == "Untagged" { return true }
                return $0 < $1
            }
            
            for key in sortedKeys {
                let groupAnns = dict[key] ?? []
                for (i, ann) in groupAnns.enumerated() {
                    let col = i % cols
                    let row = i / cols
                    let targetX = Double(CGFloat(col) * hSpace + cardW / 2 + gridGap)
                    let targetY = Double(yOffset + CGFloat(row) * vSpace + cardH / 2 + gridGap + 60) // 60 for lane header
                    targetPositions[ann.id] = (x: targetX, y: targetY)
                }
                let rowsNeeded = CGFloat((groupAnns.count + cols - 1) / cols)
                yOffset += rowsNeeded * vSpace + 120
            }
        } else {
            for (i, ann) in annotations.enumerated() {
                let col = i % cols
                let row = i / cols
                let targetX = Double(CGFloat(col) * hSpace + cardW / 2 + gridGap)
                let targetY = Double(CGFloat(row) * vSpace + cardH / 2 + gridGap)
                targetPositions[ann.id] = (x: targetX, y: targetY)
            }
        }

        withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
            for ann in annotations {
                if let pos = targetPositions[ann.id] {
                    ann.corkboardX = pos.x
                    ann.corkboardY = pos.y
                }
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

// MARK: - Swim Lane Backgrounds
struct SwimLaneBackgrounds: View {
    let annotations: [SDAnnotation]
    let cardW: CGFloat
    let cardH: CGFloat
    let gridGap: CGFloat
    
    private func calculateRects() -> [(key: String, count: Int, y: CGFloat)] {
        let cols = max(1, Int(sqrt(Double(annotations.count) * 1.4)))
        let vSpace = cardH + gridGap
        
        var dict: [String: [SDAnnotation]] = [:]
        for ann in annotations {
            let tags = (ann.tags ?? []) + (ann.readwiseTags ?? []) + (ann.readwiseDocumentTags ?? [])
            let primaryTag = tags.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "Untagged"
            dict[primaryTag, default: []].append(ann)
        }
        
        let sortedKeys = dict.keys.sorted {
            if $0 == "Untagged" { return false }
            if $1 == "Untagged" { return true }
            return $0 < $1
        }
        
        var currentY: CGFloat = gridGap
        var rects: [(key: String, count: Int, y: CGFloat)] = []
        
        for key in sortedKeys {
            let groupAnns = dict[key] ?? []
            rects.append((key: key, count: groupAnns.count, y: currentY))
            let rowsNeeded = CGFloat((groupAnns.count + cols - 1) / cols)
            currentY += rowsNeeded * vSpace + 120
        }
        
        return rects
    }

    var body: some View {
        let rects = calculateRects()
        return ZStack(alignment: .topLeading) {
            ForEach(rects, id: \.key) { rect in
                VStack(alignment: .leading) {
                    HStack {
                        Text(rect.key == "Untagged" ? "Untagged" : "#\(rect.key)")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.textSecondary)
                        Text("\(rect.count)")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.2), in: Capsule())
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .position(x: 400, y: rect.y + 30) // Positioned near the top left of the lane
            }
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

// MARK: - Card Canvas Drag Optimization Wrapper

struct IndexCardCanvasWrapperView: View {
    @Bindable var annotation: SDAnnotation
    let pdfs: [SDConvertedPDF]
    @Binding var liftedCardID: UUID?
    var matchesActiveTags: Bool
    let cardW: CGFloat
    let cardH: CGFloat
    var onDelete: () -> Void
    var onSave: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        let baseX = CGFloat(annotation.corkboardX ?? 0)
        let baseY = CGFloat(annotation.corkboardY ?? 0)
        let isLifted = liftedCardID == annotation.id

        IndexCardView(
            annotation: annotation,
            pdfs: pdfs,
            isLifted: isLifted,
            onDelete: onDelete
        )
        .opacity(matchesActiveTags ? 1.0 : 0.25)
        .position(
            x: baseX + dragOffset.width,
            y: baseY + dragOffset.height
        )
        .zIndex(isLifted ? 100 : 0)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { v in
                    if liftedCardID != annotation.id {
                        liftedCardID = annotation.id
                        HapticEngine.selection()
                    }
                    dragOffset = v.translation
                    isDragging = true
                }
                .onEnded { v in
                    annotation.corkboardX = Double(baseX + v.translation.width)
                    annotation.corkboardY = Double(baseY + v.translation.height)
                    dragOffset = .zero
                    isDragging = false
                    liftedCardID = nil
                    onSave()
                }
        )
    }
}

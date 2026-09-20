import SwiftUI
import PDFKit
import CoreGraphics

/// InksyncPro NeoFlow Studio: An elevated, tactile evolution of Onyx Boox NeoReader.
/// Provides direct on-canvas draggable dashed split lines with magnetic gutter snapping,
/// M x N matrix grid presets, asymmetric comic layouts, outer margin crop ticks,
/// per-quadrant 8-point interactive custom boundary adjustments,
/// and an interactive full-screen Tap-to-Preview reader simulator before saving.
public struct BooxSectionFlowWorkspace: View {
    // Media Source: Either a live PDFPage or a Comic UIImage
    public let pdfPage: PDFPage?
    public let comicImage: UIImage?
    public let pageIndex: Int

    @Binding public var isPresented: Bool
    public let onApply: (BooxSectionFlowConfig, Int) -> Void

    @ObservedObject private var prefs = EBookPreferences.shared
    @State private var config: BooxSectionFlowConfig = .standardTwoByTwo
    @State private var renderedThumbnail: UIImage? = nil
    @State private var activeBlocks: [BooxSectionBlock] = []
    @State private var selectedBlockIndex: Int = 0

    // Full-Screen Tap-to-Preview Mode State
    @State private var showReaderPreview: Bool = false
    @State private var previewBlockIndex: Int = 0

    // Margin Drag State
    private enum MarginEdge {
        case left, right, top, bottom
    }
    @State private var activeMarginEdge: MarginEdge? = nil
    @State private var dragStartTrim: CGFloat = 0.0

    // Partition Line Drag State
    private enum PartitionLineID: Equatable {
        case vertical(Int)
        case horizontal(Int)
    }
    @State private var activePartitionLine: PartitionLineID? = nil
    @State private var dragStartSplitRatio: CGFloat = 0.50

    // Selected Quadrant Resize / Move Drag State
    private enum QuadrantHandleType: Equatable {
        case topLeft, topRight, bottomLeft, bottomRight
        case topEdge, bottomEdge, leftEdge, rightEdge
        case move
    }
    @State private var activeQuadrantHandle: QuadrantHandleType? = nil
    @State private var dragStartQuadrantRect: CGRect = .zero

    // Magnetic gutter snap candidates
    @State private var magneticVerticalGutters: [CGFloat] = [0.33, 0.50, 0.66]
    @State private var magneticHorizontalGutters: [CGFloat] = [0.33, 0.50, 0.66]

    public init(
        pdfPage: PDFPage? = nil,
        comicImage: UIImage? = nil,
        pageIndex: Int,
        initialBlockIndex: Int = 0,
        isPresented: Binding<Bool>,
        onApply: @escaping (BooxSectionFlowConfig, Int) -> Void
    ) {
        self.pdfPage = pdfPage
        self.comicImage = comicImage
        self.pageIndex = pageIndex
        self._isPresented = isPresented
        self.onApply = onApply
        self._selectedBlockIndex = State(initialValue: initialBlockIndex)
        self._previewBlockIndex = State(initialValue: initialBlockIndex)
    }

    public var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height

            ZStack {
                Color.inkBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    topNavigationBar

                    HStack(spacing: 0) {
                        // Left Tool Palette (Boox Docked Sidebar)
                        leftToolPalette
                            .frame(width: isLandscape ? 84 : 72)
                            .background(Color.inkSurfaceRaised.opacity(0.95))
                            .overlay(
                                Rectangle()
                                    .fill(Color.inkBorderSubtle)
                                    .frame(width: 1),
                                alignment: .trailing
                            )

                        // Center Canvas (Interactive Workspace)
                        centerCanvasArea(size: CGSize(
                            width: geo.size.width - (isLandscape ? 84 : 72),
                            height: geo.size.height - 110
                        ))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    bottomSafeguardBar
                }

                // Interactive Tap-to-Preview Full-Screen Simulator Overlay
                if showReaderPreview {
                    liveReaderPreviewOverlay
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        .zIndex(500)
                }
            }
        }
        .task {
            config = prefs.booxSectionFlowConfig
            loadPageThumbnail()
            recomputeBlocks()
        }
    }

    // MARK: - Top Navigation Bar (Compact & Responsive)

    private var topNavigationBar: some View {
        HStack(spacing: 8) {
            Button {
                HapticEngine.light()
                isPresented = false
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(Color.inkTextPrimary)
            }

            Spacer()

            // Compact Title & Page Badge (Never clipped on iPhone portrait)
            HStack(spacing: 5) {
                Image(systemName: "rectangle.split.3x3")
                    .foregroundColor(.inkGreen)
                    .font(.system(size: 12, weight: .bold))
                Text("NeoFlow")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(Color.inkTextPrimary)
                Text("P. \(pageIndex + 1)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.inkSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.inkSurfaceRaised))
            }

            Spacer()

            // Tap to Preview Button
            Button {
                HapticEngine.selection()
                previewBlockIndex = selectedBlockIndex
                withAnimation(.easeInOut(duration: 0.22)) {
                    showReaderPreview = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("Preview")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundColor(Color.inkGreen)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.inkGreen.opacity(0.18))
                        .overlay(Capsule().stroke(Color.inkGreen.opacity(0.4), lineWidth: 1))
                )
            }

            // Reset Button
            Button {
                HapticEngine.selection()
                config = .standardTwoByTwo
                config.customBlockOverrides = [:]
                recomputeBlocks()
            } label: {
                Text("Reset")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.inkSecondary)
                    .padding(.horizontal, 4)
            }

            // Save / Apply Button
            Button {
                HapticEngine.medium()
                prefs.booxSectionFlowConfig = config
                onApply(config, selectedBlockIndex)
                isPresented = false
            } label: {
                Text("Save")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.inkGreen, in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Color.inkSurfaceRaised.opacity(0.98).background(.ultraThinMaterial))
        .overlay(
            Rectangle()
                .fill(Color.inkBorderSubtle)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Left Tool Palette (Boox Standard)

    private var leftToolPalette: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                // Section 1: Pages (Single vs. Spread)
                paletteSectionHeader("Pages")
                VStack(spacing: 6) {
                    paletteIconButton(
                        iconName: "doc.text",
                        title: "Single",
                        isSelected: !config.isSpreadMode
                    ) {
                        config.isSpreadMode = false
                        recomputeBlocks()
                    }

                    paletteIconButton(
                        iconName: "book.closed",
                        title: "Spread",
                        isSelected: config.isSpreadMode
                    ) {
                        config.isSpreadMode = true
                        recomputeBlocks()
                    }
                }

                Divider().background(Color.inkBorderSubtle)

                // Section 2: Blocks (M x N Matrix Presets)
                paletteSectionHeader("Blocks")
                VStack(spacing: 6) {
                    ForEach(BooxGridPreset.allCases, id: \.rawValue) { preset in
                        matrixPresetButton(preset: preset, isSelected: config.gridPreset == preset) {
                            config.gridPreset = preset
                            // Reset custom overrides when preset geometry changes
                            config.customBlockOverrides = [:]
                            if preset.rowCount == 2 {
                                config.horizontalSplitRatios = [0.50]
                            } else if preset.rowCount == 3 {
                                config.horizontalSplitRatios = [0.33, 0.66]
                            }
                            recomputeBlocks()
                        }
                    }
                }

                Divider().background(Color.inkBorderSubtle)

                // Section 3: Order (Traversal Sequence Vectors)
                paletteSectionHeader("Order")
                VStack(spacing: 6) {
                    ForEach(BooxFlowOrder.allCases, id: \.rawValue) { order in
                        paletteIconButton(
                            iconName: order.glyphSymbol,
                            title: order.displayName.components(separatedBy: " ").first ?? "",
                            isSelected: config.flowOrder == order
                        ) {
                            config.flowOrder = order
                            recomputeBlocks()
                        }
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
        }
    }

    private func paletteSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .black, design: .rounded))
            .foregroundColor(Color.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func paletteIconButton(
        iconName: String,
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            HapticEngine.selection()
            action()
        }) {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: iconName)
                        .font(.system(size: 15, weight: isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? .white : Color.inkTextPrimary)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? Color.inkGreen : Color.inkSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? Color.inkGreen : Color.inkBorderSubtle, lineWidth: 1)
                        )

                    if isSelected {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 8, height: 8)
                            .offset(x: 2, y: -2)
                    }
                }

                Text(title)
                    .font(.system(size: 8, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? Color.inkGreen : Color.inkSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func matrixPresetButton(
        preset: BooxGridPreset,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            HapticEngine.selection()
            action()
        }) {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    miniMatrixGridGlyph(for: preset, isSelected: isSelected)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? Color.inkGreen.opacity(0.18) : Color.inkSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? Color.inkGreen : Color.inkBorderSubtle, lineWidth: isSelected ? 1.8 : 1.0)
                        )

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.inkGreen)
                            .background(Circle().fill(Color.white).frame(width: 8, height: 8))
                            .offset(x: 3, y: -3)
                    }
                }

                Text(preset.rawValue)
                    .font(.system(size: 9, weight: isSelected ? .black : .medium, design: .monospaced))
                    .foregroundColor(isSelected ? Color.inkGreen : Color.inkTextPrimary)
            }
        }
    }

    @ViewBuilder
    private func miniMatrixGridGlyph(for preset: BooxGridPreset, isSelected: Bool) -> some View {
        let strokeColor = isSelected ? Color.inkGreen : Color.inkSecondary
        Canvas { context, size in
            let insetRect = CGRect(x: 6, y: 6, width: size.width - 12, height: size.height - 12)
            context.stroke(Path(roundedRect: insetRect, cornerRadius: 2), with: .color(strokeColor), lineWidth: 1.2)

            let cols = preset.columnCount
            let rows = preset.rowCount

            // Draw Column Dividers
            if cols == 2 {
                var p = Path()
                p.move(to: CGPoint(x: insetRect.midX, y: insetRect.minY))
                p.addLine(to: CGPoint(x: insetRect.midX, y: insetRect.maxY))
                context.stroke(p, with: .color(strokeColor.opacity(0.8)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
            } else if cols == 3 {
                let w3 = insetRect.width / 3.0
                var p = Path()
                p.move(to: CGPoint(x: insetRect.minX + w3, y: insetRect.minY))
                p.addLine(to: CGPoint(x: insetRect.minX + w3, y: insetRect.maxY))
                p.move(to: CGPoint(x: insetRect.minX + (w3 * 2.0), y: insetRect.minY))
                p.addLine(to: CGPoint(x: insetRect.minX + (w3 * 2.0), y: insetRect.maxY))
                context.stroke(p, with: .color(strokeColor.opacity(0.8)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
            }

            // Draw Row Dividers
            if rows == 2 {
                var p = Path()
                p.move(to: CGPoint(x: insetRect.minX, y: insetRect.midY))
                p.addLine(to: CGPoint(x: insetRect.maxX, y: insetRect.midY))
                context.stroke(p, with: .color(strokeColor.opacity(0.8)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
            } else if rows == 3 {
                let h3 = insetRect.height / 3.0
                var p = Path()
                p.move(to: CGPoint(x: insetRect.minX, y: insetRect.minY + h3))
                p.addLine(to: CGPoint(x: insetRect.maxX, y: insetRect.minY + h3))
                p.move(to: CGPoint(x: insetRect.minX, y: insetRect.minY + (h3 * 2.0)))
                p.addLine(to: CGPoint(x: insetRect.maxX, y: insetRect.minY + (h3 * 2.0)))
                context.stroke(p, with: .color(strokeColor.opacity(0.8)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
            }
        }
    }

    // MARK: - Center Canvas Area

    @ViewBuilder
    private func centerCanvasArea(size: CGSize) -> some View {
        ZStack {
            Color.inkBackground

            if let thumb = renderedThumbnail {
                let imgW = thumb.size.width
                let imgH = thumb.size.height
                let scale = min((size.width - 48) / max(1, imgW), (size.height - 48) / max(1, imgH))
                let renderW = imgW * scale
                let renderH = imgH * scale
                let originX = (size.width - renderW) / 2.0
                let originY = (size.height - renderH) / 2.0

                let cropX = originX + (renderW * config.leftMarginTrim)
                let cropY = originY + (renderH * config.topMarginTrim)
                let cropW = max(20, renderW * (1.0 - config.leftMarginTrim - config.rightMarginTrim))
                let cropH = max(20, renderH * (1.0 - config.topMarginTrim - config.bottomMarginTrim))

                ZStack {
                    // 1. Base Document Page Image
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: renderW, height: renderH)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: Color.black.opacity(0.35), radius: 12, y: 6)

                    // 2. Outer Page Limits Crop Frame
                    Rectangle()
                        .stroke(Color.inkTextPrimary.opacity(0.30), lineWidth: 1.0)
                        .frame(width: cropW, height: cropH)
                        .position(x: cropX + (cropW / 2.0), y: cropY + (cropH / 2.0))

                    // 3. Circled Sequence Badges & Quadrant Selection Overlay (Layer 10)
                    sequenceBadgesOverlay(originX: originX, originY: originY, renderW: renderW, renderH: renderH)
                        .zIndex(10)

                    // 4. Draggable Dashed Partition Lines with Center Grips (Layer 150)
                    partitionLinesOverlay(cropX: cropX, cropY: cropY, cropW: cropW, cropH: cropH)
                        .zIndex(150)

                    // 5. Draggable Margin Crop Handles (Layer 200)
                    marginCropHandles(originX: originX, originY: originY, renderW: renderW, renderH: renderH, cropX: cropX, cropY: cropY, cropW: cropW, cropH: cropH)
                        .zIndex(200)

                    // 6. Selected Quadrant 8-Point Resize Handles & Move Controller (Layer 250)
                    selectedQuadrantHandlesOverlay(originX: originX, originY: originY, renderW: renderW, renderH: renderH)
                        .zIndex(250)
                }
                .frame(width: size.width, height: size.height)
            } else {
                ProgressView()
                    .tint(Color.inkGreen)
            }
        }
    }

    // MARK: - Draggable Dashed Partition Lines with Multi-Row & Gutter Snapping

    @ViewBuilder
    private func partitionLinesOverlay(cropX: CGFloat, cropY: CGFloat, cropW: CGFloat, cropH: CGFloat) -> some View {
        let preset = config.gridPreset

        // 1. Vertical Split Line (2-Column Presets)
        if preset.columnCount == 2 {
            let splitX = cropX + (cropW * config.verticalSplitRatio)
            let isDragging = (activePartitionLine == .vertical(0))

            ZStack {
                // Dashed Vertical Line
                Path { p in
                    p.move(to: CGPoint(x: splitX, y: cropY))
                    p.addLine(to: CGPoint(x: splitX, y: cropY + cropH))
                }
                .stroke(isDragging ? Color.inkGreen : Color.inkTextPrimary.opacity(0.75), style: StrokeStyle(lineWidth: isDragging ? 2.5 : 1.5, dash: [6, 4]))

                // Invisible 44pt Touch Corridor & Tactile Center Grip
                VStack {
                    Spacer()
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(isDragging ? .white : Color.inkTextPrimary)
                    }
                    .frame(width: 26, height: 26)
                    .background(isDragging ? Color.inkGreen : Color.inkSurfaceRaised.opacity(0.95))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(isDragging ? Color.white : Color.inkBorderSubtle, lineWidth: 1.2))
                    .shadow(color: Color.black.opacity(0.35), radius: 3)
                    Spacer()
                }
                .frame(width: 44, height: cropH)
                .contentShape(Rectangle())
                .position(x: splitX, y: cropY + (cropH / 2.0))
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if activePartitionLine != .vertical(0) {
                                activePartitionLine = .vertical(0)
                                dragStartSplitRatio = config.verticalSplitRatio
                            }
                            let deltaRatio = value.translation.width / cropW
                            var newRatio = max(0.15, min(0.85, dragStartSplitRatio + deltaRatio))

                            // Magnetic Gutter Snapping
                            for candidate in magneticVerticalGutters {
                                let candX = candidate * cropW
                                let currX = newRatio * cropW
                                if abs(currX - candX) < 14 {
                                    newRatio = candidate
                                    HapticEngine.selection()
                                    break
                                }
                            }
                            config.verticalSplitRatio = newRatio
                            recomputeBlocks()
                        }
                        .onEnded { _ in
                            activePartitionLine = nil
                            HapticEngine.light()
                        }
                )
            }
        }

        // 2. Horizontal Split Line (2-Row Presets)
        if preset.rowCount == 2 {
            let splitRatio = config.horizontalSplitRatios.first ?? 0.50
            let splitY = cropY + (cropH * splitRatio)
            let isDragging = (activePartitionLine == .horizontal(0))

            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: cropX, y: splitY))
                    p.addLine(to: CGPoint(x: cropX + cropW, y: splitY))
                }
                .stroke(isDragging ? Color.inkGreen : Color.inkTextPrimary.opacity(0.75), style: StrokeStyle(lineWidth: isDragging ? 2.5 : 1.5, dash: [6, 4]))

                // Invisible 44pt Touch Corridor & Tactile Center Grip
                HStack {
                    Spacer()
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(isDragging ? .white : Color.inkTextPrimary)
                        .frame(width: 26, height: 26)
                        .background(isDragging ? Color.inkGreen : Color.inkSurfaceRaised.opacity(0.95))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(isDragging ? Color.white : Color.inkBorderSubtle, lineWidth: 1.2))
                        .shadow(color: Color.black.opacity(0.35), radius: 3)
                    Spacer()
                }
                .frame(width: cropW, height: 44)
                .contentShape(Rectangle())
                .position(x: cropX + (cropW / 2.0), y: splitY)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if activePartitionLine != .horizontal(0) {
                                activePartitionLine = .horizontal(0)
                                dragStartSplitRatio = config.horizontalSplitRatios.first ?? 0.50
                            }
                            let deltaRatio = value.translation.height / cropH
                            var newRatio = max(0.15, min(0.85, dragStartSplitRatio + deltaRatio))

                            // Magnetic Gutter Snapping
                            for candidate in magneticHorizontalGutters {
                                let candY = candidate * cropH
                                let currY = newRatio * cropH
                                if abs(currY - candY) < 14 {
                                    newRatio = candidate
                                    HapticEngine.selection()
                                    break
                                }
                            }
                            config.horizontalSplitRatios = [newRatio]
                            recomputeBlocks()
                        }
                        .onEnded { _ in
                            activePartitionLine = nil
                            HapticEngine.light()
                        }
                )
            }
        }

        // 3. Horizontal Split Lines (3-Row Presets: 1x3, 2x3, 3x3)
        if preset.rowCount == 3 {
            let splits = config.horizontalSplitRatios.count >= 2 ? config.horizontalSplitRatios : [0.33, 0.66]
            let splitY0 = cropY + (cropH * splits[0])
            let splitY1 = cropY + (cropH * splits[1])

            // Tier Split Line 0 (Top / Mid boundary)
            let isDragging0 = (activePartitionLine == .horizontal(0))
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: cropX, y: splitY0))
                    p.addLine(to: CGPoint(x: cropX + cropW, y: splitY0))
                }
                .stroke(isDragging0 ? Color.inkGreen : Color.inkTextPrimary.opacity(0.75), style: StrokeStyle(lineWidth: isDragging0 ? 2.5 : 1.5, dash: [6, 4]))

                HStack {
                    Spacer()
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(isDragging0 ? .white : Color.inkTextPrimary)
                        .frame(width: 24, height: 24)
                        .background(isDragging0 ? Color.inkGreen : Color.inkSurfaceRaised.opacity(0.95))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(isDragging0 ? Color.white : Color.inkBorderSubtle, lineWidth: 1.2))
                        .shadow(color: Color.black.opacity(0.35), radius: 3)
                    Spacer()
                }
                .frame(width: cropW, height: 44)
                .contentShape(Rectangle())
                .position(x: cropX + (cropW / 2.0), y: splitY0)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if activePartitionLine != .horizontal(0) {
                                activePartitionLine = .horizontal(0)
                                dragStartSplitRatio = splits[0]
                            }
                            let deltaRatio = value.translation.height / cropH
                            let maxAllowed = splits[1] - 0.08
                            let newRatio = max(0.10, min(maxAllowed, dragStartSplitRatio + deltaRatio))
                            config.horizontalSplitRatios = [newRatio, splits[1]]
                            recomputeBlocks()
                        }
                        .onEnded { _ in
                            activePartitionLine = nil
                            HapticEngine.light()
                        }
                )
            }

            // Tier Split Line 1 (Mid / Bot boundary)
            let isDragging1 = (activePartitionLine == .horizontal(1))
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: cropX, y: splitY1))
                    p.addLine(to: CGPoint(x: cropX + cropW, y: splitY1))
                }
                .stroke(isDragging1 ? Color.inkGreen : Color.inkTextPrimary.opacity(0.75), style: StrokeStyle(lineWidth: isDragging1 ? 2.5 : 1.5, dash: [6, 4]))

                HStack {
                    Spacer()
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(isDragging1 ? .white : Color.inkTextPrimary)
                        .frame(width: 24, height: 24)
                        .background(isDragging1 ? Color.inkGreen : Color.inkSurfaceRaised.opacity(0.95))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(isDragging1 ? Color.white : Color.inkBorderSubtle, lineWidth: 1.2))
                        .shadow(color: Color.black.opacity(0.35), radius: 3)
                    Spacer()
                }
                .frame(width: cropW, height: 44)
                .contentShape(Rectangle())
                .position(x: cropX + (cropW / 2.0), y: splitY1)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if activePartitionLine != .horizontal(1) {
                                activePartitionLine = .horizontal(1)
                                dragStartSplitRatio = splits[1]
                            }
                            let deltaRatio = value.translation.height / cropH
                            let minAllowed = splits[0] + 0.08
                            let newRatio = max(minAllowed, min(0.90, dragStartSplitRatio + deltaRatio))
                            config.horizontalSplitRatios = [splits[0], newRatio]
                            recomputeBlocks()
                        }
                        .onEnded { _ in
                            activePartitionLine = nil
                            HapticEngine.light()
                        }
                )
            }
        }
    }

    // MARK: - Margin Crop Tick Handles (Apple HIG >= 44pt Touch Targets)

    @ViewBuilder
    private func marginCropHandles(
        originX: CGFloat,
        originY: CGFloat,
        renderW: CGFloat,
        renderH: CGFloat,
        cropX: CGFloat,
        cropY: CGFloat,
        cropW: CGFloat,
        cropH: CGFloat
    ) -> some View {
        // Left Margin Handle
        marginHandlePill(
            isVertical: true,
            position: CGPoint(x: cropX, y: cropY + cropH / 2.0),
            isActive: activeMarginEdge == .left
        ) {
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if activeMarginEdge != .left {
                        activeMarginEdge = .left
                        dragStartTrim = config.leftMarginTrim
                    }
                    let deltaNorm = value.translation.width / renderW
                    config.leftMarginTrim = max(0.0, min(0.30, dragStartTrim + deltaNorm))
                    recomputeBlocks()
                }
                .onEnded { _ in
                    activeMarginEdge = nil
                    HapticEngine.light()
                }
        }

        // Right Margin Handle
        marginHandlePill(
            isVertical: true,
            position: CGPoint(x: cropX + cropW, y: cropY + cropH / 2.0),
            isActive: activeMarginEdge == .right
        ) {
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if activeMarginEdge != .right {
                        activeMarginEdge = .right
                        dragStartTrim = config.rightMarginTrim
                    }
                    let deltaNorm = value.translation.width / renderW
                    config.rightMarginTrim = max(0.0, min(0.30, dragStartTrim - deltaNorm))
                    recomputeBlocks()
                }
                .onEnded { _ in
                    activeMarginEdge = nil
                    HapticEngine.light()
                }
        }

        // Top Margin Handle
        marginHandlePill(
            isVertical: false,
            position: CGPoint(x: cropX + cropW / 2.0, y: cropY),
            isActive: activeMarginEdge == .top
        ) {
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if activeMarginEdge != .top {
                        activeMarginEdge = .top
                        dragStartTrim = config.topMarginTrim
                    }
                    let deltaNorm = value.translation.height / renderH
                    config.topMarginTrim = max(0.0, min(0.30, dragStartTrim + deltaNorm))
                    recomputeBlocks()
                }
                .onEnded { _ in
                    activeMarginEdge = nil
                    HapticEngine.light()
                }
        }

        // Bottom Margin Handle
        marginHandlePill(
            isVertical: false,
            position: CGPoint(x: cropX + cropW / 2.0, y: cropY + cropH),
            isActive: activeMarginEdge == .bottom
        ) {
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if activeMarginEdge != .bottom {
                        activeMarginEdge = .bottom
                        dragStartTrim = config.bottomMarginTrim
                    }
                    let deltaNorm = value.translation.height / renderH
                    config.bottomMarginTrim = max(0.0, min(0.30, dragStartTrim - deltaNorm))
                    recomputeBlocks()
                }
                .onEnded { _ in
                    activeMarginEdge = nil
                    HapticEngine.light()
                }
        }
    }

    private func marginHandlePill(
        isVertical: Bool,
        position: CGPoint,
        isActive: Bool,
        gesture: () -> some Gesture
    ) -> some View {
        ZStack {
            // Invisible HIG Touch Frame (>= 44pt)
            Color.clear
                .frame(width: isVertical ? 44 : 54, height: isVertical ? 54 : 44)
                .contentShape(Rectangle())

            // Tactile Handle Visual
            Capsule()
                .fill(isActive ? Color.inkGreen : Color.white)
                .frame(width: isVertical ? 7 : 32, height: isVertical ? 32 : 7)
                .overlay(Capsule().stroke(Color.black.opacity(0.3), lineWidth: 0.8))
                .shadow(color: Color.black.opacity(0.4), radius: 4, y: 1)
        }
        .position(position)
        .gesture(gesture())
    }

    // MARK: - Circled Sequence Badges & Quadrant Selection Overlay

    @ViewBuilder
    private func sequenceBadgesOverlay(
        originX: CGFloat,
        originY: CGFloat,
        renderW: CGFloat,
        renderH: CGFloat
    ) -> some View {
        ForEach(activeBlocks) { block in
            let norm = block.normalizedRect
            let rectW = renderW * norm.width
            let rectH = renderH * norm.height
            let rectX = originX + (renderW * norm.minX)
            let rectY = originY + (renderH * (1.0 - norm.maxY))

            let isSelected = selectedBlockIndex == block.stepOrder

            ZStack(alignment: .center) {
                // Subtle boundary fill & active glow
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.inkGreen : Color.inkBorderSubtle.opacity(0.6), lineWidth: isSelected ? 2.5 : 1.0)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.inkGreen.opacity(0.12) : Color.clear)
                    )

                // Circled Number Badge (①, ②, ③, ④)
                HStack(spacing: 3) {
                    Text("\(block.stepOrder + 1)")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundColor(isSelected ? .white : Color.inkTextPrimary)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(isSelected ? Color.inkGreen : Color.inkSurfaceRaised.opacity(0.92))
                        )
                        .overlay(
                            Circle()
                                .stroke(isSelected ? Color.white : Color.inkBorderSubtle, lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.3), radius: 2)

                    if rectW > 70 {
                        Text(block.label.components(separatedBy: "(").first ?? "")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(isSelected ? Color.inkGreen : Color.inkSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(3)
            }
            .frame(width: rectW, height: rectH)
            .position(x: rectX + (rectW / 2.0), y: rectY + (rectH / 2.0))
            .contentShape(Rectangle())
            .onTapGesture {
                HapticEngine.selection()
                selectedBlockIndex = block.stepOrder
            }
        }
    }

    // MARK: - Selected Quadrant 8-Point Resize Handles & Move Controller

    @ViewBuilder
    private func selectedQuadrantHandlesOverlay(
        originX: CGFloat,
        originY: CGFloat,
        renderW: CGFloat,
        renderH: CGFloat
    ) -> some View {
        if selectedBlockIndex < activeBlocks.count {
            let block = activeBlocks[selectedBlockIndex]
            let norm = block.normalizedRect
            let rectW = renderW * norm.width
            let rectH = renderH * norm.height
            let rectX = originX + (renderW * norm.minX)
            let rectY = originY + (renderH * (1.0 - norm.maxY))

            // Current top-origin normalized bounding box
            let topNorm = CGRect(
                x: norm.minX,
                y: max(0.0, 1.0 - norm.maxY),
                width: norm.width,
                height: norm.height
            )

            ZStack {
                // 1. Top-Left Corner Handle
                quadrantCornerHandle(
                    position: CGPoint(x: rectX, y: rectY),
                    handleType: .topLeft
                ) {
                    quadrantResizeGesture(handleType: .topLeft, baseRect: topNorm, renderW: renderW, renderH: renderH)
                }

                // 2. Top-Right Corner Handle
                quadrantCornerHandle(
                    position: CGPoint(x: rectX + rectW, y: rectY),
                    handleType: .topRight
                ) {
                    quadrantResizeGesture(handleType: .topRight, baseRect: topNorm, renderW: renderW, renderH: renderH)
                }

                // 3. Bottom-Left Corner Handle
                quadrantCornerHandle(
                    position: CGPoint(x: rectX, y: rectY + rectH),
                    handleType: .bottomLeft
                ) {
                    quadrantResizeGesture(handleType: .bottomLeft, baseRect: topNorm, renderW: renderW, renderH: renderH)
                }

                // 4. Bottom-Right Corner Handle
                quadrantCornerHandle(
                    position: CGPoint(x: rectX + rectW, y: rectY + rectH),
                    handleType: .bottomRight
                ) {
                    quadrantResizeGesture(handleType: .bottomRight, baseRect: topNorm, renderW: renderW, renderH: renderH)
                }

                // 5. Top Edge Handle
                quadrantEdgeHandle(
                    isVertical: false,
                    position: CGPoint(x: rectX + rectW / 2.0, y: rectY),
                    handleType: .topEdge
                ) {
                    quadrantResizeGesture(handleType: .topEdge, baseRect: topNorm, renderW: renderW, renderH: renderH)
                }

                // 6. Bottom Edge Handle
                quadrantEdgeHandle(
                    isVertical: false,
                    position: CGPoint(x: rectX + rectW / 2.0, y: rectY + rectH),
                    handleType: .bottomEdge
                ) {
                    quadrantResizeGesture(handleType: .bottomEdge, baseRect: topNorm, renderW: renderW, renderH: renderH)
                }

                // 7. Left Edge Handle
                quadrantEdgeHandle(
                    isVertical: true,
                    position: CGPoint(x: rectX, y: rectY + rectH / 2.0),
                    handleType: .leftEdge
                ) {
                    quadrantResizeGesture(handleType: .leftEdge, baseRect: topNorm, renderW: renderW, renderH: renderH)
                }

                // 8. Right Edge Handle
                quadrantEdgeHandle(
                    isVertical: true,
                    position: CGPoint(x: rectX + rectW, y: rectY + rectH / 2.0),
                    handleType: .rightEdge
                ) {
                    quadrantResizeGesture(handleType: .rightEdge, baseRect: topNorm, renderW: renderW, renderH: renderH)
                }

                // Floating "Reset Quadrant" Chip if this quadrant has a custom override
                if config.customBlockOverrides[selectedBlockIndex] != nil {
                    HStack(spacing: 5) {
                        Text("Custom Bounds")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(.inkGreen)
                        Button {
                            HapticEngine.selection()
                            config.customBlockOverrides.removeValue(forKey: selectedBlockIndex)
                            recomputeBlocks()
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 8, weight: .bold))
                                Text("Reset")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.inkGreen))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.inkSurfaceRaised).overlay(Capsule().stroke(Color.inkGreen.opacity(0.5), lineWidth: 1)))
                    .shadow(color: Color.black.opacity(0.3), radius: 3)
                    .position(x: rectX + rectW / 2.0, y: max(originY + 12, rectY - 14))
                }
            }
        }
    }

    private func quadrantCornerHandle(
        position: CGPoint,
        handleType: QuadrantHandleType,
        gesture: () -> some Gesture
    ) -> some View {
        ZStack {
            Color.clear
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())

            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.inkGreen, lineWidth: 2.5))
                .shadow(color: Color.black.opacity(0.35), radius: 3)
        }
        .position(position)
        .gesture(gesture())
    }

    private func quadrantEdgeHandle(
        isVertical: Bool,
        position: CGPoint,
        handleType: QuadrantHandleType,
        gesture: () -> some Gesture
    ) -> some View {
        ZStack {
            Color.clear
                .frame(width: isVertical ? 44 : 50, height: isVertical ? 50 : 44)
                .contentShape(Rectangle())

            Capsule()
                .fill(Color.white)
                .frame(width: isVertical ? 6 : 22, height: isVertical ? 22 : 6)
                .overlay(Capsule().stroke(Color.inkGreen, lineWidth: 1.5))
                .shadow(color: Color.black.opacity(0.35), radius: 3)
        }
        .position(position)
        .gesture(gesture())
    }

    private func quadrantResizeGesture(
        handleType: QuadrantHandleType,
        baseRect: CGRect,
        renderW: CGFloat,
        renderH: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if activeQuadrantHandle != handleType {
                    activeQuadrantHandle = handleType
                    dragStartQuadrantRect = baseRect
                }
                let dx = value.translation.width / renderW
                let dy = value.translation.height / renderH

                var newX = dragStartQuadrantRect.minX
                var newY = dragStartQuadrantRect.minY
                var newW = dragStartQuadrantRect.width
                var newH = dragStartQuadrantRect.height

                switch handleType {
                case .topLeft:
                    let clampedDx = min(dx, dragStartQuadrantRect.width - 0.08)
                    let clampedDy = min(dy, dragStartQuadrantRect.height - 0.08)
                    newX = max(0.0, dragStartQuadrantRect.minX + clampedDx)
                    newY = max(0.0, dragStartQuadrantRect.minY + clampedDy)
                    newW = max(0.08, dragStartQuadrantRect.maxX - newX)
                    newH = max(0.08, dragStartQuadrantRect.maxY - newY)
                case .topRight:
                    let clampedDy = min(dy, dragStartQuadrantRect.height - 0.08)
                    newY = max(0.0, dragStartQuadrantRect.minY + clampedDy)
                    newW = max(0.08, min(1.0 - newX, dragStartQuadrantRect.width + dx))
                    newH = max(0.08, dragStartQuadrantRect.maxY - newY)
                case .bottomLeft:
                    let clampedDx = min(dx, dragStartQuadrantRect.width - 0.08)
                    newX = max(0.0, dragStartQuadrantRect.minX + clampedDx)
                    newW = max(0.08, dragStartQuadrantRect.maxX - newX)
                    newH = max(0.08, min(1.0 - newY, dragStartQuadrantRect.height + dy))
                case .bottomRight:
                    newW = max(0.08, min(1.0 - newX, dragStartQuadrantRect.width + dx))
                    newH = max(0.08, min(1.0 - newY, dragStartQuadrantRect.height + dy))
                case .topEdge:
                    let clampedDy = min(dy, dragStartQuadrantRect.height - 0.08)
                    newY = max(0.0, dragStartQuadrantRect.minY + clampedDy)
                    newH = max(0.08, dragStartQuadrantRect.maxY - newY)
                case .bottomEdge:
                    newH = max(0.08, min(1.0 - newY, dragStartQuadrantRect.height + dy))
                case .leftEdge:
                    let clampedDx = min(dx, dragStartQuadrantRect.width - 0.08)
                    newX = max(0.0, dragStartQuadrantRect.minX + clampedDx)
                    newW = max(0.08, dragStartQuadrantRect.maxX - newX)
                case .rightEdge:
                    newW = max(0.08, min(1.0 - newX, dragStartQuadrantRect.width + dx))
                case .move:
                    newX = max(0.0, min(1.0 - newW, dragStartQuadrantRect.minX + dx))
                    newY = max(0.0, min(1.0 - newH, dragStartQuadrantRect.minY + dy))
                }

                let updatedRect = CGRect(x: newX, y: newY, width: newW, height: newH)
                config.customBlockOverrides[selectedBlockIndex] = updatedRect
                recomputeBlocks()
            }
            .onEnded { _ in
                activeQuadrantHandle = nil
                HapticEngine.light()
            }
    }

    // MARK: - Bottom Safeguard Tool Bar

    private var bottomSafeguardBar: some View {
        HStack(spacing: 20) {
            // Toggle 1: Auto crop page margin after pagination
            Toggle(isOn: $config.autoCropAfterPagination) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto crop margin after pagination")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.inkTextPrimary)
                    Text("Removes whitespace inside each divided block")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(Color.inkSecondary)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: .inkGreen))

            Spacer()

            // Toggle 2: Connection Redundancy for Text Splitting Avoidance
            Toggle(isOn: $config.connectionRedundancy) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Connection Redundancy (Beta)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color.inkTextPrimary)
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundColor(Color.inkSecondary)
                    }
                    Text("Overlap buffer prevents severed text & panels")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(Color.inkSecondary)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: .inkGreen))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.inkSurfaceRaised.opacity(0.98).background(.ultraThinMaterial))
        .overlay(
            Rectangle()
                .fill(Color.inkBorderSubtle)
                .frame(height: 1),
            alignment: .top
        )
    }

    // MARK: - Interactive Full-Screen Tap-to-Preview Simulator

    private var liveReaderPreviewOverlay: some View {
        ZStack {
            Color.inkBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Preview Header Bar
                HStack(spacing: 12) {
                    Button {
                        HapticEngine.light()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showReaderPreview = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .bold))
                            Text("Editor")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(Color.inkTextPrimary)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Image(systemName: "play.circle.fill")
                            .foregroundColor(.inkGreen)
                            .font(.system(size: 13, weight: .bold))
                        Text("Reader Preview")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(Color.inkTextPrimary)
                        Text("· Block \(previewBlockIndex + 1) of \(activeBlocks.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.inkSecondary)
                    }

                    Spacer()

                    // Direct Save & Finish Button
                    Button {
                        HapticEngine.medium()
                        prefs.booxSectionFlowConfig = config
                        onApply(config, previewBlockIndex)
                        isPresented = false
                    } label: {
                        Text("Save & Read")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.inkGreen, in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(Color.inkSurfaceRaised.opacity(0.98).background(.ultraThinMaterial))
                .overlay(Rectangle().fill(Color.inkBorderSubtle).frame(height: 1), alignment: .bottom)

                // Viewport Reader Simulator
                GeometryReader { viewportGeo in
                    let viewW = viewportGeo.size.width
                    let viewH = viewportGeo.size.height

                    ZStack {
                        Color.black.ignoresSafeArea()

                        if let thumb = renderedThumbnail, previewBlockIndex < activeBlocks.count {
                            let block = activeBlocks[previewBlockIndex]
                            let targetNorm = config.connectionRedundancy ? block.redundantRect : block.normalizedRect
                            let cgW = CGFloat(thumb.cgImage?.width ?? 100)
                            let cgH = CGFloat(thumb.cgImage?.height ?? 100)

                            // Target crop box in CGImage space (Y=0 is top)
                            let cropBox = CGRect(
                                x: max(0, targetNorm.minX * cgW),
                                y: max(0, (1.0 - targetNorm.maxY) * cgH),
                                width: min(cgW, targetNorm.width * cgW),
                                height: min(cgH, targetNorm.height * cgH)
                            )

                            if let croppedCG = thumb.cgImage?.cropping(to: cropBox) {
                                Image(uiImage: UIImage(cgImage: croppedCG))
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: viewW, maxHeight: viewH)
                                    .id(previewBlockIndex)
                                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            }
                        }

                        // Floating HUD Tier Badge (Matches Live Reader Engine)
                        if previewBlockIndex < activeBlocks.count {
                            let block = activeBlocks[previewBlockIndex]
                            VStack {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.inkGreen)
                                        .frame(width: 8, height: 8)
                                    Text(block.label)
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundColor(Color.inkTextPrimary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.inkSurfaceRaised.opacity(0.92)).background(.ultraThinMaterial))
                                .overlay(Capsule().stroke(Color.inkBorderSubtle, lineWidth: 1))
                                .shadow(color: Color.black.opacity(0.35), radius: 8, y: 3)
                                .padding(.top, 14)

                                Spacer()
                            }
                        }

                        // Interactive Tap Zones (Apple Books / Kindle Standard)
                        HStack(spacing: 0) {
                            // Left Tap Zone: Previous Quadrant
                            Color.clear
                                .frame(maxWidth: viewW * 0.35, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if previewBlockIndex > 0 {
                                        HapticEngine.selection()
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                            previewBlockIndex -= 1
                                        }
                                    }
                                }

                            Spacer()

                            // Right Tap Zone: Next Quadrant
                            Color.clear
                                .frame(maxWidth: viewW * 0.35, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if previewBlockIndex < activeBlocks.count - 1 {
                                        HapticEngine.selection()
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                            previewBlockIndex += 1
                                        }
                                    }
                                }
                        }
                    }
                }

                // Bottom Preview Step Controller
                HStack(spacing: 16) {
                    Button {
                        if previewBlockIndex > 0 {
                            HapticEngine.selection()
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                previewBlockIndex -= 1
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Prev")
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(previewBlockIndex > 0 ? Color.inkTextPrimary : Color.inkSecondary.opacity(0.35))
                    }
                    .disabled(previewBlockIndex == 0)

                    Spacer()

                    // Step Indicator Dots
                    HStack(spacing: 6) {
                        ForEach(0..<activeBlocks.count, id: \.self) { idx in
                            Circle()
                                .fill(idx == previewBlockIndex ? Color.inkGreen : Color.inkSecondary.opacity(0.4))
                                .frame(width: idx == previewBlockIndex ? 8 : 5, height: idx == previewBlockIndex ? 8 : 5)
                                .onTapGesture {
                                    HapticEngine.selection()
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                        previewBlockIndex = idx
                                    }
                                }
                        }
                    }

                    Spacer()

                    Button {
                        if previewBlockIndex < activeBlocks.count - 1 {
                            HapticEngine.selection()
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                previewBlockIndex += 1
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Next")
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(previewBlockIndex < activeBlocks.count - 1 ? Color.inkTextPrimary : Color.inkSecondary.opacity(0.35))
                    }
                    .disabled(previewBlockIndex >= activeBlocks.count - 1)
                }
                .padding(.horizontal, 20)
                .frame(height: 48)
                .background(Color.inkSurfaceRaised.opacity(0.98).background(.ultraThinMaterial))
                .overlay(Rectangle().fill(Color.inkBorderSubtle).frame(height: 1), alignment: .top)
            }
        }
    }

    // MARK: - Data Synchronization

    private func loadPageThumbnail() {
        if let page = pdfPage {
            let size = CGSize(width: 450, height: 600)
            let thumb = page.thumbnail(of: size, for: .cropBox)
            self.renderedThumbnail = thumb
            let gutters = BooxSectionFlowEngine.shared.detectMagneticGutters(in: thumb)
            self.magneticVerticalGutters = gutters.vertical
            self.magneticHorizontalGutters = gutters.horizontal
        } else if let img = comicImage {
            self.renderedThumbnail = img
            let gutters = BooxSectionFlowEngine.shared.detectMagneticGutters(in: img)
            self.magneticVerticalGutters = gutters.vertical
            self.magneticHorizontalGutters = gutters.horizontal
        }
    }

    private func recomputeBlocks() {
        let blocks = BooxSectionFlowEngine.shared.generateBlocks(config: config, space: .pdf)
        self.activeBlocks = blocks
        if selectedBlockIndex >= blocks.count {
            selectedBlockIndex = max(0, blocks.count - 1)
        }
        if previewBlockIndex >= blocks.count {
            previewBlockIndex = max(0, blocks.count - 1)
        }
    }
}

import SwiftUI
import PDFKit

/// InksyncPro NeoFlow Studio: An elevated, tactile evolution of Onyx Boox NeoReader.
/// Provides direct on-canvas draggable dashed split lines with magnetic gutter snapping,
/// M x N matrix grid presets, asymmetric comic layouts, outer margin crop ticks,
/// traversal order vectors, and connection redundancy toggles.
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
    @State private var showPiPPreview: Bool = false
    @State private var isDraggingVerticalSplit: Bool = false
    @State private var isDraggingHorizontalSplit: Bool = false

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

                // Floating Live Viewport PiP Preview Card
                if showPiPPreview {
                    floatingPiPCard
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .task {
            config = prefs.booxSectionFlowConfig
            loadPageThumbnail()
            recomputeBlocks()
        }
    }

    // MARK: - Top Navigation Bar

    private var topNavigationBar: some View {
        HStack(spacing: 12) {
            Button {
                HapticEngine.light()
                isPresented = false
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                    Text("Cancel")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(Color.inkTextPrimary)
            }

            Spacer()

            // Title & Mode Indicator
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.3x3")
                    .foregroundColor(.inkGreen)
                    .font(.system(size: 13, weight: .bold))
                Text("NeoFlow Studio")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(Color.inkTextPrimary)
                Text("· Page \(pageIndex + 1)")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Color.inkSecondary)
            }

            Spacer()

            // Live PiP Preview Toggle
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    showPiPPreview.toggle()
                }
                HapticEngine.selection()
            } label: {
                Image(systemName: showPiPPreview ? "pip.exit" : "pip.enter")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(showPiPPreview ? .inkGreen : Color.inkSecondary)
                    .padding(6)
                    .background(Circle().fill(Color.inkSurfaceRaised))
            }

            // Reset Button
            Button {
                HapticEngine.selection()
                config = .standardTwoByTwo
                recomputeBlocks()
            } label: {
                Text("Reset")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.inkSecondary)
            }

            // Save / Apply Button
            Button {
                HapticEngine.medium()
                prefs.booxSectionFlowConfig = config
                onApply(config, selectedBlockIndex)
                isPresented = false
            } label: {
                Text("Save")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.inkGreen, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
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
            VStack(spacing: 16) {
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
                            // Reset default split ratios matching the preset
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
                    // Geometric Mini-Matrix Preview
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
                let scale = min((size.width - 40) / max(1, imgW), (size.height - 40) / max(1, imgH))
                let renderW = imgW * scale
                let renderH = imgH * scale
                let originX = (size.width - renderW) / 2.0
                let originY = (size.height - renderH) / 2.0

                ZStack {
                    // 1. Base Document Page Image
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: renderW, height: renderH)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: Color.black.opacity(0.35), radius: 12, y: 6)

                    // 2. Outer Page Limits Crop Frame & Ticks
                    let cropX = originX + (renderW * config.leftMarginTrim)
                    let cropY = originY + (renderH * config.topMarginTrim)
                    let cropW = max(20, renderW * (1.0 - config.leftMarginTrim - config.rightMarginTrim))
                    let cropH = max(20, renderH * (1.0 - config.topMarginTrim - config.bottomMarginTrim))

                    // Solid margin crop bounding frame
                    Rectangle()
                        .stroke(Color.inkTextPrimary.opacity(0.40), lineWidth: 1.0)
                        .frame(width: cropW, height: cropH)
                        .position(x: cropX + (cropW / 2.0), y: cropY + (cropH / 2.0))

                    // Draggable Margin Crop Tick Handles
                    marginCropHandles(originX: originX, originY: originY, renderW: renderW, renderH: renderH, cropX: cropX, cropY: cropY, cropW: cropW, cropH: cropH)

                    // 3. Draggable Dashed Partition Lines (Movable Gutters)
                    partitionLinesOverlay(cropX: cropX, cropY: cropY, cropW: cropW, cropH: cropH)

                    // 4. Circled Sequence Badges (①, ②, ③, ④)
                    sequenceBadgesOverlay(originX: originX, originY: originY, renderW: renderW, renderH: renderH)
                }
                .frame(width: size.width, height: size.height)
            } else {
                ProgressView()
                    .tint(Color.inkGreen)
            }
        }
    }

    // MARK: - Draggable Dashed Partition Lines with Magnetic Gutter Snapping

    @ViewBuilder
    private func partitionLinesOverlay(cropX: CGFloat, cropY: CGFloat, cropW: CGFloat, cropH: CGFloat) -> some View {
        let preset = config.gridPreset

        // Vertical Dashed Split Line (for 2-column layouts)
        if preset.columnCount == 2 {
            let splitX = cropX + (cropW * config.verticalSplitRatio)
            Path { p in
                p.move(to: CGPoint(x: splitX, y: cropY))
                p.addLine(to: CGPoint(x: splitX, y: cropY + cropH))
            }
            .stroke(isDraggingVerticalSplit ? Color.inkGreen : Color.inkTextPrimary.opacity(0.85), style: StrokeStyle(lineWidth: isDraggingVerticalSplit ? 2.5 : 1.5, dash: [5, 4]))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDraggingVerticalSplit = true
                        let localX = value.location.x - cropX
                        var ratio = max(0.15, min(0.85, localX / cropW))

                        // Magnetic Gutter Snapping: Snap if within 14 points of candidate valley
                        for candidate in magneticVerticalGutters {
                            let candX = candidate * cropW
                            if abs(localX - candX) < 14 {
                                ratio = candidate
                                HapticEngine.selection()
                                break
                            }
                        }
                        config.verticalSplitRatio = ratio
                        recomputeBlocks()
                    }
                    .onEnded { _ in
                        isDraggingVerticalSplit = false
                        HapticEngine.light()
                    }
            )
        }

        // Horizontal Dashed Split Line (for 2-row layouts)
        if preset.rowCount == 2 {
            let splitRatio = config.horizontalSplitRatios.first ?? 0.50
            let splitY = cropY + (cropH * splitRatio)
            Path { p in
                p.move(to: CGPoint(x: cropX, y: splitY))
                p.addLine(to: CGPoint(x: cropX + cropW, y: splitY))
            }
            .stroke(isDraggingHorizontalSplit ? Color.inkGreen : Color.inkTextPrimary.opacity(0.85), style: StrokeStyle(lineWidth: isDraggingHorizontalSplit ? 2.5 : 1.5, dash: [5, 4]))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDraggingHorizontalSplit = true
                        let localY = value.location.y - cropY
                        var ratio = max(0.15, min(0.85, localY / cropH))

                        // Magnetic Gutter Snapping
                        for candidate in magneticHorizontalGutters {
                            let candY = candidate * cropH
                            if abs(localY - candY) < 14 {
                                ratio = candidate
                                HapticEngine.selection()
                                break
                            }
                        }
                        config.horizontalSplitRatios = [ratio]
                        recomputeBlocks()
                    }
                    .onEnded { _ in
                        isDraggingHorizontalSplit = false
                        HapticEngine.light()
                    }
            )
        }
    }

    // MARK: - Margin Crop Tick Handles

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
        marginHandle(isVertical: true, position: CGPoint(x: cropX, y: cropY + cropH / 2.0)) { delta in
            let newTrim = max(0.0, min(0.25, config.leftMarginTrim + (delta / renderW)))
            config.leftMarginTrim = newTrim
            recomputeBlocks()
        }

        // Right Margin Handle
        marginHandle(isVertical: true, position: CGPoint(x: cropX + cropW, y: cropY + cropH / 2.0)) { delta in
            let newTrim = max(0.0, min(0.25, config.rightMarginTrim - (delta / renderW)))
            config.rightMarginTrim = newTrim
            recomputeBlocks()
        }

        // Top Margin Handle
        marginHandle(isVertical: false, position: CGPoint(x: cropX + cropW / 2.0, y: cropY)) { delta in
            let newTrim = max(0.0, min(0.25, config.topMarginTrim + (delta / renderH)))
            config.topMarginTrim = newTrim
            recomputeBlocks()
        }

        // Bottom Margin Handle
        marginHandle(isVertical: false, position: CGPoint(x: cropX + cropW / 2.0, y: cropY + cropH)) { delta in
            let newTrim = max(0.0, min(0.25, config.bottomMarginTrim - (delta / renderH)))
            config.bottomMarginTrim = newTrim
            recomputeBlocks()
        }
    }

    private func marginHandle(
        isVertical: Bool,
        position: CGPoint,
        onDrag: @escaping (CGFloat) -> Void
    ) -> some View {
        Capsule()
            .fill(Color.inkTextPrimary)
            .frame(width: isVertical ? 5 : 24, height: isVertical ? 24 : 5)
            .overlay(Capsule().stroke(Color.white, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.4), radius: 3)
            .position(position)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let delta = isVertical ? value.translation.width : value.translation.height
                        onDrag(delta * 0.15)
                    }
            )
    }

    // MARK: - Dynamic Circled Sequence Badges

    @ViewBuilder
    private func sequenceBadgesOverlay(
        originX: CGFloat,
        originY: CGFloat,
        renderW: CGFloat,
        renderH: CGFloat
    ) -> some View {
        ForEach(activeBlocks) { block in
            // Use UIKit coordinate space (Y=0 is top) for screen overlay
            let norm = block.normalizedRect
            let rectW = renderW * norm.width
            let rectH = renderH * norm.height
            let rectX = originX + (renderW * norm.minX)
            // For PDF space: convert from bottom-left to top-left Y
            let rectY = (pdfPage != nil) ? originY + (renderH * (1.0 - norm.maxY)) : originY + (renderH * norm.minY)

            let isSelected = selectedBlockIndex == block.stepOrder

            ZStack(alignment: .center) {
                // Subtle boundary fill & active glow
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.inkGreen : Color.clear, lineWidth: 2.0)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.inkGreen.opacity(0.18) : Color.clear)
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

    // MARK: - Floating PiP Live Viewport Card

    private var floatingPiPCard: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack {
                Text("Device Framing · Block \(selectedBlockIndex + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(Color.inkTextPrimary)
                Spacer()
                Button {
                    withAnimation { showPiPPreview = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.inkSecondary)
                }
            }

            // Cropped representation of selected block with green redundancy tint
            ZStack {
                Color.black
                if let thumb = renderedThumbnail, selectedBlockIndex < activeBlocks.count {
                    let block = activeBlocks[selectedBlockIndex]
                    let norm = block.normalizedRect
                    let cgW = CGFloat(thumb.cgImage?.width ?? 100)
                    let cgH = CGFloat(thumb.cgImage?.height ?? 100)
                    let cropBox = CGRect(
                        x: norm.minX * cgW,
                        y: (pdfPage != nil ? (1.0 - norm.maxY) : norm.minY) * cgH,
                        width: norm.width * cgW,
                        height: norm.height * cgH
                    )
                    if let cropped = thumb.cgImage?.cropping(to: cropBox) {
                        Image(uiImage: UIImage(cgImage: cropped))
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }

                // Redundancy buffer indicator
                if config.connectionRedundancy {
                    VStack {
                        Rectangle()
                            .fill(Color.inkGreen.opacity(0.25))
                            .frame(height: 8)
                        Spacer()
                        Rectangle()
                            .fill(Color.inkGreen.opacity(0.25))
                            .frame(height: 8)
                    }
                }
            }
            .frame(width: 140, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.inkGreen, lineWidth: 1))
        }
        .padding(10)
        .background(Color.inkSurfaceRaised.opacity(0.96).background(.ultraThinMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.4), radius: 12, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.trailing, 16)
        .padding(.top, 56)
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
        let space: BooxCoordinateSpace = (pdfPage != nil) ? .pdf : .image
        let blocks = BooxSectionFlowEngine.shared.generateBlocks(config: config, space: space)
        self.activeBlocks = blocks
        if selectedBlockIndex >= blocks.count {
            selectedBlockIndex = max(0, blocks.count - 1)
        }
    }
}

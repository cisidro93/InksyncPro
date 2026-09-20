import SwiftUI
import PDFKit

/// Quick Adjust HUD for PDF Smart Tiers & Guided Column Flow.
/// Allows the user to visually inspect and customize quadrant tiers, column divisions,
/// page limits / margins, and reading flow orders (Boox NeoReader standard) directly over the current PDF page thumbnail.
/// Supports responsive 2-column split in landscape mode so the confirmation button is always 1-tap accessible.
struct PDFSmartTiersQuickAdjustHUD: View {
    let currentPage: PDFPage
    let pageIndex: Int
    @Binding var isPresented: Bool
    let onApplyConfiguration: (PDFTierGuideConfiguration) -> Void

    @ObservedObject private var prefs = EBookPreferences.shared
    @State private var config: PDFTierGuideConfiguration = .standardTwoColumn
    @State private var pageThumbnail: UIImage? = nil
    @State private var previewQuadrants: [PDFTierQuadrant] = []
    @State private var isMarginsExpanded: Bool = false

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height

            if isLandscape {
                landscapeLayout(size: geo.size)
            } else {
                portraitLayout(size: geo.size)
            }
        }
        .task {
            config = prefs.pdfTierConfiguration
            renderPageThumbnail()
            recomputePreviewQuadrants()
        }
    }

    // MARK: - Landscape Layout (Split View: Visualizer Left, Controls + Pinned Button Right)

    @ViewBuilder
    private func landscapeLayout(size: CGSize) -> some View {
        HStack(spacing: 16) {
            // Left Column: Full-height Page Visualizer
            let visualizerWidth = max(180, min(360, size.width * 0.42))
            let visualizerHeight = max(180, size.height - 32)
            pageVisualizer(availableWidth: visualizerWidth, availableHeight: visualizerHeight)
                .frame(width: visualizerWidth, height: visualizerHeight)

            // Right Column: Header, Presets, Scrollable Controls, Pinned Apply Button
            VStack(spacing: 10) {
                headerBar

                presetStrip

                ScrollView(.vertical, showsIndicators: true) {
                    controlsView
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
                }

                applyButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .background(
            Color.inkSurfaceRaised.opacity(0.98)
                .background(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.inkBorderSubtle, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 24, y: 12)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Portrait Layout

    @ViewBuilder
    private func portraitLayout(size: CGSize) -> some View {
        VStack(spacing: 12) {
            headerBar

            presetStrip

            let visualizerHeight: CGFloat = min(220, max(160, size.height * 0.28))
            pageVisualizer(availableWidth: size.width - 48, availableHeight: visualizerHeight)
                .frame(height: visualizerHeight)
                .padding(.horizontal, 8)

            ScrollView(.vertical, showsIndicators: true) {
                controlsView
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }

            applyButton
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: 440)
        .background(
            Color.inkSurfaceRaised.opacity(0.98)
                .background(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.inkBorderSubtle, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 24, y: 12)
        .padding(.horizontal, 12)
    }

    // MARK: - Subviews & Controls

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.inkGreen)

            VStack(alignment: .leading, spacing: 2) {
                Text("Smart Tiers & Column Flow")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(Color.inkTextPrimary)
                Text("Guided reading with Boox section flow & custom margins")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(Color.inkSecondary)
            }

            Spacer()

            Button {
                HapticEngine.light()
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Color.inkSecondary)
            }
        }
    }

    private var presetStrip: some View {
        HStack(spacing: 6) {
            ForEach(PDFTierLayoutPreset.allCases) { preset in
                let isSelected = config.preset == preset
                Button {
                    HapticEngine.selection()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        config.preset = preset
                        switch preset {
                        case .twoColumn:
                            config.columnCount = 2
                            config.tiersPerColumn = 3
                        case .singleColumn:
                            config.columnCount = 1
                            config.tiersPerColumn = 3
                        case .threeColumn:
                            config.columnCount = 3
                            config.tiersPerColumn = 3
                        case .autoColumns:
                            config.columnCount = 2
                            config.tiersPerColumn = 3
                        }
                        recomputePreviewQuadrants()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: preset.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(preset.title)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(isSelected ? .white : Color.inkTextPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        isSelected ? Color.inkGreen : Color.inkSurfaceRaised,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(isSelected ? Color.clear : Color.inkBorderSubtle, lineWidth: 0.75)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func pageVisualizer(availableWidth: CGFloat, availableHeight: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.04))

            if let thumb = pageThumbnail {
                let imgSize = thumb.size
                let imgRatio = imgSize.width / max(1, imgSize.height)
                let containerRatio = availableWidth / max(1, availableHeight)

                let renderW: CGFloat = (imgRatio > containerRatio) ? availableWidth : (availableHeight * imgRatio)
                let renderH: CGFloat = (imgRatio > containerRatio) ? (availableWidth / imgRatio) : availableHeight

                let originX = (availableWidth - renderW) / 2.0
                let originY = (availableHeight - renderH) / 2.0

                ZStack(alignment: .topLeading) {
                    // Rendered page image
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: renderW, height: renderH)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: Color.black.opacity(0.20), radius: 8, y: 3)
                        .position(x: availableWidth / 2.0, y: availableHeight / 2.0)

                    // Page Limits Trim Frame (Subtle dashed crop boundaries)
                    let leftTrim = CGFloat(config.leftMarginTrim)
                    let rightTrim = CGFloat(config.rightMarginTrim)
                    let topTrim = CGFloat(config.topMarginTrim)
                    let botTrim = CGFloat(config.bottomMarginTrim)

                    if leftTrim > 0.001 || rightTrim > 0.001 || topTrim > 0.001 || botTrim > 0.001 {
                        let cropX = originX + (renderW * leftTrim)
                        let cropY = originY + (renderH * topTrim)
                        let cropW = max(0, renderW * (1.0 - leftTrim - rightTrim))
                        let cropH = max(0, renderH * (1.0 - topTrim - botTrim))

                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.inkBlue.opacity(0.65), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                            .frame(width: cropW, height: cropH)
                            .position(x: cropX + cropW / 2.0, y: cropY + cropH / 2.0)
                    }

                    // Quadrant flow guides overlay (Exact letterbox-aligned coordinates)
                    ForEach(previewQuadrants) { quad in
                        let norm = quad.normalizedRect
                        // In PDFKit coordinates, Y=0 is bottom; convert to SwiftUI top-left Y
                        let rectW = renderW * norm.width
                        let rectH = renderH * norm.height
                        let rectX = originX + (renderW * norm.minX)
                        let rectY = originY + (renderH * (1.0 - norm.maxY))

                        ZStack(alignment: .center) {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.inkGreen.opacity(0.90), lineWidth: 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.inkGreen.opacity(0.14))
                                )

                            // Numbered sequence flow badge
                            HStack(spacing: 3) {
                                Text("\(quad.stepOrder + 1)")
                                    .font(.system(size: 11, weight: .black, design: .rounded))
                                    .foregroundColor(.white)
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(Color.inkGreen))
                                    .shadow(color: Color.black.opacity(0.3), radius: 2)

                                if rectW > 80 {
                                    Text(quad.label.components(separatedBy: "(").first ?? "")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(Color.inkTextPrimary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(2)
                        }
                        .frame(width: rectW, height: rectH)
                        .position(x: rectX + (rectW / 2.0), y: rectY + (rectH / 2.0))
                    }
                }
            } else {
                ProgressView()
                    .tint(.inkGreen)
            }
        }
    }

    @ViewBuilder
    private var controlsView: some View {
        VStack(spacing: 12) {
            // Boox-Style Flow Order Picker
            VStack(alignment: .leading, spacing: 6) {
                Label("Reading Flow Order", systemImage: "arrow.triangle.swap")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.inkTextPrimary)

                HStack(spacing: 6) {
                    ForEach(PDFReadingFlowOrder.allCases) { flow in
                        let isSelected = config.flowOrder == flow
                        Button {
                            HapticEngine.selection()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                config.flowOrder = flow
                                recomputePreviewQuadrants()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: flow.icon)
                                    .font(.system(size: 11, weight: .bold))
                                Text(flow.title)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(isSelected ? .white : Color.inkTextPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? Color.inkBlue : Color.inkSurfaceRaised,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isSelected ? Color.clear : Color.inkBorderSubtle, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Tiers per column
            HStack {
                Label("Tiers per Column", systemImage: "arrow.up.and.down")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.inkTextPrimary)

                Spacer()

                HStack(spacing: 6) {
                    ForEach([2, 3, 4, 5], id: \.self) { count in
                        let isTierSelected = config.tiersPerColumn == count
                        Button {
                            HapticEngine.selection()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                config.tiersPerColumn = count
                                recomputePreviewQuadrants()
                            }
                        } label: {
                            Text("\(count)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(isTierSelected ? .white : Color.inkTextPrimary)
                                .frame(width: 32, height: 28)
                                .background(isTierSelected ? Color.inkGreen : Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(isTierSelected ? Color.clear : Color.inkBorderSubtle, lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Vertical Overlap
            HStack {
                Label("Vertical Overlap", systemImage: "square.2.layers.3d.top.filled")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.inkTextPrimary)

                Spacer()

                Slider(value: $config.verticalOverlap, in: 0.05...0.30, step: 0.02) {
                    Text("Overlap")
                }
                .tint(.inkGreen)
                .frame(width: 120)
                .onChange(of: config.verticalOverlap) { _, _ in
                    recomputePreviewQuadrants()
                }

                Text("\(Int(config.verticalOverlap * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.inkSecondary)
                    .frame(width: 34, alignment: .trailing)
            }

            // Column Split (if 2-column)
            if config.preset == .twoColumn || config.columnCount == 2 {
                HStack {
                    Label("Column Split", systemImage: "arrow.left.and.right")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(Color.inkTextPrimary)

                    Spacer()

                    Slider(value: $config.columnSplitRatio, in: 0.25...0.75, step: 0.02) {
                        Text("Column Split")
                    }
                    .tint(.inkGreen)
                    .frame(width: 120)
                    .onChange(of: config.columnSplitRatio) { _, _ in
                        recomputePreviewQuadrants()
                    }

                    Text("\(Int(config.columnSplitRatio * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.inkSecondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }

            // Page Limits / Margins (Onyx Boox Feature)
            DisclosureGroup(
                isExpanded: $isMarginsExpanded,
                content: {
                    VStack(spacing: 8) {
                        marginSlider(label: "Top Trim", icon: "arrow.up.to.line", value: $config.topMarginTrim)
                        marginSlider(label: "Bottom Trim", icon: "arrow.down.to.line", value: $config.bottomMarginTrim)
                        marginSlider(label: "Left Trim", icon: "arrow.left.to.line", value: $config.leftMarginTrim)
                        marginSlider(label: "Right Trim", icon: "arrow.right.to.line", value: $config.rightMarginTrim)
                    }
                    .padding(.top, 4)
                },
                label: {
                    HStack(spacing: 6) {
                        Image(systemName: "crop")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.inkViolet)
                        Text("Page Limits & Margins")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(Color.inkTextPrimary)
                    }
                }
            )
            .accentColor(.inkSecondary)
        }
    }

    @ViewBuilder
    private func marginSlider(label: String, icon: String, value: Binding<CGFloat>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.inkSecondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.inkTextPrimary)

            Spacer()

            Slider(value: value, in: 0.0...0.25, step: 0.01) {
                Text(label)
            }
            .tint(.inkViolet)
            .frame(width: 100)
            .onChange(of: value.wrappedValue) { _, _ in
                recomputePreviewQuadrants()
            }

            Text("\(Int(value.wrappedValue * 100))%")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Color.inkSecondary)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private var applyButton: some View {
        Button {
            HapticEngine.medium()
            prefs.pdfTierConfiguration = config
            onApplyConfiguration(config)
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                Text("Apply & Start Smart Flow")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.inkGreen, in: Capsule())
            .shadow(color: Color.inkGreen.opacity(0.35), radius: 8, y: 3)
        }
    }

    private func renderPageThumbnail() {
        let size = CGSize(width: 400, height: 550)
        let thumb = currentPage.thumbnail(of: size, for: .cropBox)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            self.pageThumbnail = thumb
        }
    }

    private func recomputePreviewQuadrants() {
        let isManga = prefs.pdfRTL || UserDefaults.standard.bool(forKey: "isMangaMode")
        let quads = PDFSmartTierEngine.shared.generateQuadrants(
            for: currentPage,
            pageIndex: pageIndex,
            config: config,
            isMangaRTL: isManga
        )
        self.previewQuadrants = quads
    }
}

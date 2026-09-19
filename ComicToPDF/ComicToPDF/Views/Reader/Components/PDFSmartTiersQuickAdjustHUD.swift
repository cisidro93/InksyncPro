import SwiftUI
import PDFKit

/// Quick Adjust HUD for PDF Smart Tiers & Guided Column Flow.
/// Allows the user to visually inspect and customize quadrant tiers, column divisions,
/// and reading flows directly over the current PDF page thumbnail.
struct PDFSmartTiersQuickAdjustHUD: View {
    let currentPage: PDFPage
    let pageIndex: Int
    @Binding var isPresented: Bool
    let onApplyConfiguration: (PDFTierGuideConfiguration) -> Void

    @ObservedObject private var prefs = EBookPreferences.shared
    @State private var config: PDFTierGuideConfiguration = .standardTwoColumn
    @State private var pageThumbnail: UIImage? = nil
    @State private var previewQuadrants: [PDFTierQuadrant] = []

    var body: some View {
        VStack(spacing: 16) {
            // ── Header Bar ──────────────────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.inkGreen)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Tiers & Column Flow")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(Color.inkTextPrimary)
                    Text("Guided reading for multi-column papers & books")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(Color.inkSecondary)
                }

                Spacer()

                Button {
                    HapticEngine.light()
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Color.inkSecondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            // ── Preset Selector Strip ───────────────────────────────────
            HStack(spacing: 8) {
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
                        HStack(spacing: 5) {
                            Image(systemName: preset.icon)
                                .font(.system(size: 12, weight: .semibold))
                            Text(preset.title)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(isSelected ? .white : Color.inkTextPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
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
            .padding(.horizontal, 18)

            // ── Interactive Visualizer Card ─────────────────────────────
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .frame(height: 240)

                if let thumb = pageThumbnail {
                    GeometryReader { geo in
                        let cardW = geo.size.width
                        let cardH = geo.size.height

                        ZStack(alignment: .topLeading) {
                            // Rendered page image
                            Image(uiImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: cardW, height: cardH)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: Color.black.opacity(0.15), radius: 8, y: 4)

                            // Quadrant flow guides overlay
                            ForEach(previewQuadrants) { quad in
                                let norm = quad.normalizedRect
                                // In PDF coordinates, Y=0 is bottom; convert to SwiftUI top-left Y
                                let rectW = cardW * norm.width
                                let rectH = cardH * norm.height
                                let rectX = cardW * norm.minX
                                let rectY = cardH * (1.0 - norm.maxY)

                                ZStack(alignment: .center) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.inkGreen.opacity(0.85), lineWidth: 1.5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.inkGreen.opacity(0.12))
                                        )

                                    // Numbered sequence flow badge
                                    HStack(spacing: 3) {
                                        Text("\(quad.stepOrder + 1)")
                                            .font(.system(size: 11, weight: .black, design: .rounded))
                                            .foregroundColor(.white)
                                            .frame(width: 20, height: 20)
                                            .background(Circle().fill(Color.inkGreen))
                                            .shadow(color: Color.black.opacity(0.3), radius: 2)

                                        if rectW > 90 {
                                            Text(quad.label.components(separatedBy: "(").first ?? "")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(Color.inkTextPrimary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(3)
                                }
                                .frame(width: rectW, height: rectH)
                                .position(x: rectX + (rectW / 2.0), y: rectY + (rectH / 2.0))
                            }
                        }
                    }
                    .frame(height: 240)
                    .padding(.horizontal, 24)
                } else {
                    ProgressView()
                        .tint(.inkGreen)
                }
            }

            // ── Tiers & Overlap Controls ────────────────────────────────
            VStack(spacing: 12) {
                HStack {
                    Label("Tiers per Column", systemImage: "arrow.up.and.down")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(Color.inkTextPrimary)

                    Spacer()

                    HStack(spacing: 8) {
                        ForEach([2, 3, 4], id: \.self) { count in
                            let isTierSelected = config.tiersPerColumn == count
                            Button {
                                HapticEngine.selection()
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    config.tiersPerColumn = count
                                    recomputePreviewQuadrants()
                                }
                            } label: {
                                Text("\(count)")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundColor(isTierSelected ? .white : Color.inkTextPrimary)
                                    .frame(width: 34, height: 30)
                                    .background(isTierSelected ? Color.inkBlue : Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(isTierSelected ? Color.clear : Color.inkBorderSubtle, lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // If 2-column, provide column split adjustment
                if config.preset == .twoColumn {
                    HStack {
                        Label("Column Split", systemImage: "arrow.left.and.right")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(Color.inkTextPrimary)

                        Spacer()

                        Slider(value: $config.columnSplitRatio, in: 0.35...0.65, step: 0.02) {
                            Text("Column Split")
                        }
                        .tint(.inkGreen)
                        .frame(width: 140)
                        .onChange(of: config.columnSplitRatio) { _, _ in
                            recomputePreviewQuadrants()
                        }

                        Text("\(Int(config.columnSplitRatio * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(Color.inkSecondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 20)

            // ── Continuous Flow Guarantee Banner ────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.inkGreen)
                    .font(.system(size: 12))
                Text("This guided flow continues through the entire book")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.inkSecondary)
            }
            .padding(.vertical, 4)

            // ── Primary Action Button ───────────────────────────────────
            Button {
                HapticEngine.medium()
                onApplyConfiguration(config)
                isPresented = false
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                    Text("Apply & Start Smart Flow")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.inkGreen, in: Capsule())
                .shadow(color: Color.inkGreen.opacity(0.35), radius: 10, y: 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: 420)
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
        .padding(.horizontal, 16)
        .task {
            renderPageThumbnail()
            recomputePreviewQuadrants()
        }
    }

    private func renderPageThumbnail() {
        let size = CGSize(width: 320, height: 420)
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

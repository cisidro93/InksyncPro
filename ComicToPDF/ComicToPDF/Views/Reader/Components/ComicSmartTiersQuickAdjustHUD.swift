import SwiftUI

/// Quick Adjust HUD for Comic & Manga Smart Tiers & Guided Flow.
/// Allows the reader to visually inspect and customize tier divisions, overlap safe zones,
/// and reading flows (including Japanese Manga RTL) directly over the active comic page.
struct ComicSmartTiersQuickAdjustHUD: View {
    let pageImage: UIImage?
    let pageIndex: Int
    let isMangaMode: Bool
    @Binding var isPresented: Bool
    let onApplyConfiguration: (ComicTierGuideConfiguration) -> Void

    @ObservedObject private var prefs = EBookPreferences.shared
    @State private var config: ComicTierGuideConfiguration = .standardThreeTier
    @State private var previewQuadrants: [ComicTierQuadrant] = []

    var body: some View {
        VStack(spacing: 16) {
            // ── Header Bar ──────────────────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.inkGreen)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Comic Smart Tiers & Flow")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(Color.inkTextPrimary)
                    Text("Guided reading with customizable tiers and manga flow")
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
            HStack(spacing: 6) {
                ForEach(ComicTierLayoutPreset.allCases) { preset in
                    let isSelected = config.preset == preset
                    Button {
                        HapticEngine.selection()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            config.preset = preset
                            switch preset {
                            case .threeTier:
                                config.tierCount = 3
                                config.columnCount = 1
                                config.overlap = 0.15
                            case .twoHalves:
                                config.tierCount = 2
                                config.columnCount = 1
                                config.overlap = 0.18
                            case .yonkoma:
                                config.tierCount = 2
                                config.columnCount = 2
                                config.overlap = 0.12
                            case .fourTier:
                                config.tierCount = 4
                                config.columnCount = 1
                                config.overlap = 0.12
                            case .autoGutter:
                                config.tierCount = 3
                                config.columnCount = 1
                                config.overlap = 0.15
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
            .padding(.horizontal, 16)

            // ── Reading Direction Pill ──────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: isMangaMode ? "arrow.left.circle.fill" : "arrow.right.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isMangaMode ? Color.inkViolet : Color.inkBlue)
                Text(isMangaMode ? "Manga Reading Flow (Right-to-Left)" : "Western Reading Flow (Left-to-Right)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(isMangaMode ? Color.inkViolet : Color.inkBlue)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill((isMangaMode ? Color.inkViolet : Color.inkBlue).opacity(0.10))
            )

            // ── Interactive Visualizer Card ─────────────────────────────
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .frame(height: 240)

                if let img = pageImage {
                    GeometryReader { geo in
                        let cardW = geo.size.width
                        let cardH = geo.size.height

                        // Calculate aspect fit sizing for the comic page within card
                        let imgSize = img.size
                        let imgRatio = imgSize.width / max(1, imgSize.height)
                        let cardRatio = cardW / max(1, cardH)

                        let renderW: CGFloat
                        let renderH: CGFloat
                        if imgRatio > cardRatio {
                            renderW = cardW
                            renderH = cardW / imgRatio
                        } else {
                            renderH = cardH
                            renderW = cardH * imgRatio
                        }

                        let originX = (cardW - renderW) / 2.0
                        let originY = (cardH - renderH) / 2.0

                        ZStack(alignment: .topLeading) {
                            // Rendered page image
                            Image(uiImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: renderW, height: renderH)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .shadow(color: Color.black.opacity(0.25), radius: 8, y: 3)
                                .position(x: cardW / 2.0, y: cardH / 2.0)

                            // Quadrant flow guides overlay
                            ForEach(previewQuadrants) { quad in
                                let norm = quad.normalizedRect
                                // In Vision coordinates, Y=0 is bottom, Y=1 is top.
                                // In SwiftUI coordinates, Y=0 is top.
                                let rectW = renderW * norm.width
                                let rectH = renderH * norm.height
                                let rectX = originX + (renderW * norm.minX)
                                let rectY = originY + (renderH * (1.0 - (norm.minY + norm.height)))

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
                                            .shadow(color: Color.black.opacity(0.35), radius: 2)

                                        if rectW > 85 {
                                            Text(quad.label.components(separatedBy: "(").first ?? "")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(Color.inkTextPrimary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(3)
                                }
                                .frame(width: max(20, rectW), height: max(16, rectH))
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
                            let isTierSelected = config.tierCount == count
                            Button {
                                HapticEngine.selection()
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    config.tierCount = count
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

                // Overlap Slider
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Safety Overlap", systemImage: "rectangle.inset.filled.and.cursorarrow")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(Color.inkTextPrimary)
                        Text("Prevents dialogue bubbles from being cut off")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(Color.inkSecondary)
                    }

                    Spacer()

                    Slider(value: $config.overlap, in: 0.08...0.25, step: 0.01) {
                        Text("Overlap")
                    }
                    .tint(.inkGreen)
                    .frame(width: 120)
                    .onChange(of: config.overlap) { _, _ in
                        recomputePreviewQuadrants()
                    }

                    Text("\(Int(config.overlap * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.inkSecondary)
                        .frame(width: 38, alignment: .trailing)
                }

                // If 2-column or Yonkoma, provide column split adjustment
                if config.preset == .yonkoma || config.columnCount == 2 {
                    HStack {
                        Label("Column Split", systemImage: "arrow.left.and.right")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(Color.inkTextPrimary)

                        Spacer()

                        Slider(value: $config.columnSplitRatio, in: 0.35...0.65, step: 0.02) {
                            Text("Column Split")
                        }
                        .tint(.inkGreen)
                        .frame(width: 120)
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
                Text("This guided flow continues through the entire comic")
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
                .padding(.vertical, 12)
                .background(Color.inkGreen, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Color.inkGreen.opacity(0.35), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(
            Color.inkSurfaceRaised
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
        )
        .onAppear {
            config = prefs.comicTierConfiguration
            recomputePreviewQuadrants()
        }
    }

    private func recomputePreviewQuadrants() {
        let size = pageImage?.size ?? CGSize(width: 1200, height: 1800)
        previewQuadrants = PanelExtractor.generateComicQuadrants(
            for: size,
            isDualPage: false,
            mangaMode: isMangaMode,
            config: config,
            imageForGutterAnalysis: pageImage
        )
    }
}

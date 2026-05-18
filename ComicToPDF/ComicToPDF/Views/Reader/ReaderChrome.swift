import SwiftUI

// MARK: - ReaderChrome
//
// Redesigned after deep analysis of Panels, Comixology, Chunky, and Apple Books:
//
//  TOP BAR   — Single frosted-glass capsule bar. Back ← | Title | Actions →
//              Slides in from the top with spring physics.
//
//  BOTTOM BAR — Single frosted-glass card. Scrubber on top, action row below.
//               Slides up from the bottom with matching spring physics.
//
// Neither bar uses scattered floating circles. All controls live on one surface
// per bar, consistent with how Panels and Apple Books handle the chrome.

struct ReaderChrome: View {
    let title: String
    let pageText: String
    @Binding var isVisible: Bool
    @Environment(\.horizontalSizeClass) private var hSizeClass

    // Actions
    var onBack: () -> Void
    var onBookmark: () -> Void
    var onBookmarkActive: Bool = false
    var onSettingsToggle: () -> Void
    var onTOCToggle: (() -> Void)? = nil
    var onAnnotationsToggle: (() -> Void)? = nil

    // Scrubber
    @Binding var currentProgress: Double
    let totalPages: Int
    var customScrubber: AnyView? = nil

    // TTS
    var hasTTS: Bool = false
    var isSpeaking: Bool = false
    var onTTSToggle: (() -> Void)? = nil

    // PDF tools
    var isPDF: Bool = false
    var isReflowActive: Bool = false
    var onCropToggle: (() -> Void)? = nil
    var onReflowToggle: (() -> Void)? = nil

    // Enhancement
    var isEnhanced: Bool = false
    var onEnhanceToggle: (() -> Void)? = nil

    // Mode indicator
    var isSettingsActive: Bool = false
    var currentModeLabel: String? = nil

    // Ambient tint from current page (Panels-style)
    var ambientColor: Color = .clear

    // MARK: - Body

    var body: some View {
        VStack {
            topBar
                .offset(y: isVisible ? 0 : -12)

            Spacer()

            bottomCard
                .offset(y: isVisible ? 0 : 16)
        }
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: isVisible)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 0) {
            // ── Back button ────────────────────────────────────────────────────
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            // ── Divider ────────────────────────────────────────────────────────
            chromeDivider

            // ── Title ──────────────────────────────────────────────────────────
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)

            // ── Divider ────────────────────────────────────────────────────────
            chromeDivider

            // ── Action cluster ─────────────────────────────────────────────────
            HStack(spacing: 0) {
                if onEnhanceToggle != nil {
                    chromeButton(
                        icon: "wand.and.stars",
                        active: isEnhanced,
                        activeColor: .yellow,
                        action: { onEnhanceToggle?() }
                    )
                }

                if isPDF {
                    chromeButton(icon: "text.alignleft", active: isReflowActive, activeColor: .white) {
                        onReflowToggle?()
                    }
                    chromeButton(icon: "crop", active: false, activeColor: .white) {
                        onCropToggle?()
                    }
                }

                chromeButton(
                    icon: isSettingsActive ? "slider.horizontal.3" : "ellipsis",
                    active: isSettingsActive,
                    activeColor: .white,
                    badgeText: isSettingsActive ? currentModeLabel : nil,
                    action: onSettingsToggle
                )
            }
        }
        .frame(height: 48)
        .background(topBarBackground)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .frame(maxWidth: hSizeClass == .regular ? 680 : .infinity)  // constrain on iPad
        .padding(.horizontal, hSizeClass == .regular ? 32 : 16)
        .padding(.top, 8)
    }

    // MARK: - Bottom Card

    private var bottomCard: some View {
        VStack(spacing: 0) {
            // ── Scrubber ───────────────────────────────────────────────────────
            if let custom = customScrubber {
                custom
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            } else {
                HStack(spacing: 10) {
                    Text("1")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 20, alignment: .leading)

                    Slider(value: $currentProgress, in: 0...1)
                        .tint(Color.white)

                    Text("\(totalPages)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 20, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }

            // ── Thin divider ───────────────────────────────────────────────────
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, 16)

            // ── Action row ─────────────────────────────────────────────────────
            HStack {
                // Left cluster
                HStack(spacing: 4) {
                    barButton(
                        icon: onBookmarkActive ? "bookmark.fill" : "bookmark",
                        tint: onBookmarkActive ? .yellow : .white
                    ) {
                        HapticEngine.success()
                        onBookmark()
                    }

                    if hasTTS {
                        barButton(
                            icon: isSpeaking ? "waveform" : "headphones",
                            tint: isSpeaking ? .orange : .white
                        ) {
                            onTTSToggle?()
                        }
                    }
                }

                Spacer()

                // Page counter — centred and prominent
                Text(pageText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.12), in: Capsule())

                Spacer()

                // Right cluster
                HStack(spacing: 4) {
                    if let onTOC = onTOCToggle {
                        barButton(icon: "list.bullet", tint: .white, action: onTOC)
                    }
                    if let onAnnotations = onAnnotationsToggle {
                        barButton(icon: "pencil.and.outline", tint: .white, action: onAnnotations)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(bottomCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 18, y: -4)
        .frame(maxWidth: hSizeClass == .regular ? 680 : .infinity)  // constrain on iPad
        .padding(.horizontal, hSizeClass == .regular ? 32 : 12)
        .padding(.bottom, 12)
    }

    // MARK: - Shared Backgrounds

    private var topBarBackground: some ShapeStyle {
        AnyShapeStyle(.ultraThinMaterial)
    }

    private var bottomCardBackground: some View {
        ZStack {
            // Base: system material
            Rectangle().fill(.ultraThinMaterial)
            // Ambient tint overlay (Panels-style page colour)
            if ambientColor != .clear {
                Rectangle().fill(ambientColor.opacity(0.08))
            }
        }
    }

    // MARK: - Reusable Components

    private var chromeDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 0.5, height: 22)
    }

    /// Icon button for the top bar action cluster
    @ViewBuilder
    private func chromeButton(
        icon: String,
        active: Bool,
        activeColor: Color,
        badgeText: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(active ? activeColor : .white.opacity(0.85))
                if let badge = badgeText {
                    Text(badge)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(activeColor)
                        .lineLimit(1)
                }
            }
            .frame(width: 44, height: 44)
            .background(active ? activeColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
    }

    /// Icon button for the bottom action row
    @ViewBuilder
    private func barButton(icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }
}

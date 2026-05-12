import SwiftUI

// MARK: - Tab Definition

struct InkTabItem {
    let tag: Int
    let label: String
    let icon: String
    let activeIcon: String
}

// MARK: - Floating Glass Pill Tab Bar

struct InkTabBar: View {
    @Binding var selectedTab: Int
    @Binding var isHidden: Bool
    var convertingProgress: Double = 0
    var isConverting: Bool = false
    var convertingMessage: String = ""

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass

    private let allTabs: [InkTabItem] = [
        InkTabItem(tag: 0, label: "Library",    icon: "books.vertical",        activeIcon: "books.vertical.fill"),
        InkTabItem(tag: 1, label: "Reader",     icon: "book",                  activeIcon: "book.fill"),
        InkTabItem(tag: 2, label: "Inbox",      icon: "tray",                  activeIcon: "tray.full.fill"),
        InkTabItem(tag: 3, label: "Devices",    icon: "ipad.and.iphone",       activeIcon: "ipad.and.iphone.fill"),
        InkTabItem(tag: 4, label: "Work Area",  icon: "scissors",              activeIcon: "scissors.badge.ellipsis"),
        InkTabItem(tag: 5, label: "Highlights", icon: "text.badge.star",       activeIcon: "text.badge.star"),
        InkTabItem(tag: 6, label: "Settings",   icon: "gear",                  activeIcon: "gearshape.fill"),
    ]

    // Always show all 7 tabs on every device and orientation
    private var visibleTabs: [InkTabItem] { allTabs }

    // iPhone landscape = compact height + compact width
    private var isLandscapePhone: Bool {
        hSizeClass == .compact && vSizeClass == .compact
    }

    private var horizontalPadding: CGFloat {
        if isLandscapePhone { return 60 }   // landscape iPhone: tight outer padding
        if hSizeClass == .compact { return 18 } // portrait iPhone: small padding
        return 80                            // iPad / regular
    }

    private var pillVerticalPadding: CGFloat { isLandscapePhone ? 5 : 10 }
    private var iconSize: CGFloat         { isLandscapePhone ? 15 : 17 }
    private var activeIconSize: CGFloat   { isLandscapePhone ? 17 : 19 }
    private var iconFrameHeight: CGFloat  { isLandscapePhone ? 22 : 34 }

    var body: some View {
        VStack(spacing: 6) {
            // Conversion progress banner (floats just above the pill)
            if isConverting {
                conversionBanner
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // The floating pill
            HStack(spacing: 0) {
                ForEach(visibleTabs, id: \.tag) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, pillVerticalPadding)
            .background(
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.06 : 0.5),
                                    Color.white.opacity(0.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.18 : 0.7),
                                Color.white.opacity(colorScheme == .dark ? 0.04 : 0.2)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.55 : 0.18),
                radius: 28, y: 8
            )
        }
        .padding(.horizontal, horizontalPadding)
        .offset(y: isHidden ? 100 : 0)
        .opacity(isHidden ? 0 : 1)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isHidden)
        .animation(.easeInOut(duration: 0.25), value: isConverting)
    }

    // MARK: - Tab Button

    @ViewBuilder
    private func tabButton(_ tab: InkTabItem) -> some View {
        let isActive = selectedTab == tab.tag

        Button {
            if selectedTab == tab.tag {
                // Tap active tab again → scroll-to-top signal + subtle haptic
                HapticEngine.medium()
                NotificationCenter.default.post(
                    name: NSNotification.Name("InkTab_DoubleTap_\(tab.tag)"),
                    object: nil
                )
            } else {
                HapticEngine.light()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                    selectedTab = tab.tag
                }
            }
        } label: {
            VStack(spacing: isLandscapePhone ? 1 : 3) {
                ZStack {
                    // Active glow — skip in landscape to save height
                    if isActive && !isLandscapePhone {
                        Circle()
                            .fill(Color.orange.opacity(0.18))
                            .frame(width: 38, height: 38)
                            .blur(radius: 10)
                    }

                    Image(systemName: isActive ? tab.activeIcon : tab.icon)
                        .font(.system(
                            size: isActive ? activeIconSize : iconSize,
                            weight: isActive ? .semibold : .regular
                        ))
                        .foregroundStyle(
                            isActive
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [Color.orange, Color.orange.opacity(0.75)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                  )
                                : AnyShapeStyle(Color.primary.opacity(0.50))
                        )
                        .scaleEffect(isActive ? 1.08 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.60), value: isActive)
                }
                .frame(width: 44, height: iconFrameHeight)

                // Active dot — smaller in landscape
                Circle()
                    .fill(Color.orange)
                    .frame(width: isLandscapePhone ? 3 : 4, height: isLandscapePhone ? 3 : 4)
                    .opacity(isActive ? 1 : 0)
                    .scaleEffect(isActive ? 1 : 0.1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isActive)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .frame(maxWidth: .infinity)
    }

    // MARK: - Conversion Banner

    private var conversionBanner: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.orange)

                Text(convertingMessage.isEmpty ? "Converting…" : convertingMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Text("\(Int(convertingProgress * 100))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.orange)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1)).frame(height: 3)
                    Capsule()
                        .fill(
                            LinearGradient(colors: [Color.orange, Color.orange.opacity(0.6)],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: geo.size.width * convertingProgress, height: 3)
                        .animation(.easeInOut(duration: 0.3), value: convertingProgress)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Scroll-Hide Preference Key

struct InkScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Drop this on any ScrollView to auto-hide the InkTabBar on scroll down
struct InkTabBarScrollDetector: ViewModifier {
    let onScrollDown: () -> Void
    let onScrollUp: () -> Void

    @State private var lastOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: InkScrollOffsetKey.self,
                    value: geo.frame(in: .named("InkScrollSpace")).minY
                )
            }
        )
        .onPreferenceChange(InkScrollOffsetKey.self) { offset in
            let delta = offset - lastOffset
            if delta < -12 { onScrollDown() }
            else if delta > 12 { onScrollUp() }
            lastOffset = offset
        }
    }
}

extension View {
    func inkTabBarScrollDetect(onDown: @escaping () -> Void, onUp: @escaping () -> Void) -> some View {
        self.modifier(InkTabBarScrollDetector(onScrollDown: onDown, onScrollUp: onUp))
    }

    /// Keep a tab view always in the hierarchy (preserves state) but hide + disable
    /// it when `isVisible` is false. Drop-in replacement for TabView tab management.
    @ViewBuilder
    func tabVisible(_ isVisible: Bool) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}

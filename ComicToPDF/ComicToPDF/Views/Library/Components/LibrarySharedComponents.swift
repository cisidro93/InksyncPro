import SwiftUI

// MARK: - Scroll Offset Preference Key
// Used by LibraryGridView and LibraryListView to report their scroll position
// up through the view hierarchy so LibraryHeaderView can auto-collapse.
struct LibraryScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Header Pin Mode
// Controls whether the header auto-collapses on scroll (auto), is locked open
// (pinnedExpanded), or locked collapsed (pinnedCollapsed).
enum HeaderPinMode: String {
    case auto             = "auto"
    case pinnedExpanded   = "expanded"
    case pinnedCollapsed  = "collapsed"
}

enum LibraryRowAction {
    case read, covers, fetchMetadata, editMetadata, export, share, sync, rename, addToSeries, delete, favorite, details, toggleVault, saveToDrive, sendToKindle, convert
}

// MARK: - Theme Colors
// Thin compatibility shim — all values are routed to the canonical ink* design tokens
// defined in DesignSystem.swift. Do not add new raw values here; add to DesignSystem.
struct Theme {
    static let bg             = Color.inkBackground
    static let surface        = Color.inkSurface
    static let surfaceElevated = Color.inkSurfaceRaised
    static let orange         = Color.inkAmber
    static let blue           = Color.inkBlue
    static let purple         = Color.inkViolet
    static let green          = Color.inkGreen
    static let red            = Color.inkRed
    static let text           = Color.inkTextPrimary
    static let textSecondary  = Color.inkTextSecondary
    static let textTertiary   = Color.inkTextTertiary
}

// MARK: - Action Pill Component
struct ActionPill: View {
    let title: String
    let icon: String
    let color: Color // Used to tint the icon in the new Liquid Glass look
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(LinearGradient(colors: [Theme.text.opacity(0.4), Theme.text.opacity(0.0)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
            .shadow(color: Color(UIColor.systemBackground).opacity(0.15), radius: 8, y: 4)
        }
    }
}

// MARK: - Empty State
struct ModernEmptyState: View {
    var onImport: () -> Void
    var onFolderImport: (() -> Void)?
    var onCloudImport: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Illustrated icon with ambient glow
            ZStack {
                // Ambient neural glow blob
                NeuralExpressiveBackground()
                    .frame(width: 144, height: 144)
                    .clipShape(Circle())

                // Icon card
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: 96, height: 96)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Theme.orange.opacity(0.2), radius: 20, y: 8)

                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.orange, Theme.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.bottom, 32)

            // Headline
            Text("Your Library is Empty")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Theme.text)
                .padding(.bottom, 8)

            Text("Import comics, manga, and books to get started.\nThey'll be organised automatically by series.")
                .font(.system(size: 15))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 40)
                .padding(.bottom, 32)

            // Primary CTA: Import
            Button(action: onImport) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Import File")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: 260)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: [Theme.orange, Color(red: 0.9, green: 0.45, blue: 0.1)],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .shadow(color: Theme.orange.opacity(0.4), radius: 12, y: 6)
            }
            .padding(.bottom, 12)

            // Secondary CTA: Cloud
            if let onCloud = onCloudImport {
                Button(action: onCloud) {
                    HStack(spacing: 8) {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Browse Cloud")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(Theme.text)
                    .frame(maxWidth: 260)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
                }
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
// MARK: - Library Index Scrubber (on-demand, Contacts-style)
// At rest: FULLY INVISIBLE — no permanent ribbon on the right edge.
// On touch/drag: springs open to the full letter list with selection haptics.
// Auto-hides 1.5 seconds after the user lifts their finger.
struct LibraryIndexScrubber: View {
    let onScrub: (String) -> Void
    let letters: [String] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ#".map { String($0) }

    @State private var isExpanded: Bool = false
    @State private var activeLetter: String? = nil
    @State private var hideTask: Task<Void, Never>? = nil

    var body: some View {
        GeometryReader { geo in
            let itemHeight = geo.size.height / CGFloat(letters.count)

            ZStack(alignment: .trailing) {
                // ── Invisible wide hit area (touch anywhere on right 28pt strip) ──
                Color.clear
                    .frame(width: 28)

                // ── Expanded letter list ──────────────────────────────────────────────
                if isExpanded {
                    VStack(spacing: 0) {
                        ForEach(letters, id: \.self) { char in
                            Text(char)
                                .font(.system(size: 11, weight: .heavy, design: .rounded))
                                .foregroundColor(
                                    activeLetter == char
                                        ? Theme.blue
                                        : Theme.textSecondary.opacity(0.75)
                                )
                                .frame(maxWidth: .infinity)
                                .frame(height: itemHeight)
                                .scaleEffect(activeLetter == char ? 1.25 : 1.0)
                        }
                    }
                    .frame(width: 28)
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    )
                    .overlay(
                        Capsule()
                            .stroke(Theme.text.opacity(0.08), lineWidth: 0.5)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
                }
                // NO collapsed handle — completely invisible at rest
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Cancel any pending hide on new touch
                        hideTask?.cancel()

                        // Expand on first touch
                        if !isExpanded {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
                                isExpanded = true
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }

                        // Letter tracking
                        let idx = max(0, min(letters.count - 1, Int(value.location.y / itemHeight)))
                        let letter = letters[idx]
                        if activeLetter != letter {
                            activeLetter = letter
                            onScrub(letter)
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                    .onEnded { _ in
                        activeLetter = nil
                        // Auto-collapse after 1.5 seconds of inactivity
                        hideTask = Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                withAnimation(.easeOut(duration: 0.2)) { isExpanded = false }
                            }
                        }
                    }
            )
        }
        .frame(width: 28)
    }
}

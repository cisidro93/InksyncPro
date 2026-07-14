import SwiftUI

// MARK: - Scroll Offset Preference Key
// Used by LibraryGridView and LibraryListView to report their scroll position
// up through the view hierarchy so LibraryHeaderView can auto-collapse.
struct LibraryScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct LibraryCellFramePreferenceKey: PreferenceKey {
    typealias Value = [String: CGRect]
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
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
// MARK: - 7. Quick Jump Overlay (Dynamic grid selector for small screens)
struct QuickJumpOverlay: View {
    @Binding var isPresented: Bool
    let availableLetters: Set<String>
    let onJump: (String) -> Void
    
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    private let letters = "#ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }
    
    var body: some View {
        ZStack {
            // Semi-transparent backdrop to blur out background
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isPresented = false
                    }
                }
            
            VStack(spacing: 16) {
                // Header
                HStack {
                    Label {
                        Text("Jump to Section")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    } icon: {
                        Image(systemName: "abc")
                            .foregroundStyle(Theme.blue)
                    }
                    
                    Spacer()
                    
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            isPresented = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(Theme.textSecondary)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
                
                // Grid of Letters
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(letters, id: \.self) { char in
                        let hasItems = availableLetters.contains(char)
                        Button {
                            if hasItems {
                                onJump(char)
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    isPresented = false
                                }
                                HapticEngine.medium()
                            }
                        } label: {
                            Text(char)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundColor(hasItems ? .white : .white.opacity(0.2))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(hasItems ? Theme.blue.opacity(0.55) : Color.white.opacity(0.04))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(hasItems ? Theme.blue.opacity(0.3) : Color.clear, lineWidth: 1)
                                )
                        }
                        .disabled(!hasItems)
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color(hex: "#0e0e16").opacity(0.85))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .padding(.horizontal, 28)
            .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }
}

// MARK: - LazyView Helper
/// A thin helper that wraps a view constructor closure to bypass eager NavigationLink evaluation.
struct LazyView<Content: View>: View {
    let build: () -> Content
    init(_ build: @escaping () -> Content) {
        self.build = build
    }
    var body: Content {
        build()
    }
}

// MARK: - Tactile Button Style
/// ButtonStyle that shrinks slightly on press and triggers a light haptic tick.
struct TactileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}


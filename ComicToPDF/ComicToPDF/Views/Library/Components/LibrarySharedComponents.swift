import SwiftUI

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
                // Ambient glow blob
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [Theme.orange.opacity(0.35), Theme.purple.opacity(0.15), .clear]),
                            center: .center,
                            startRadius: 20,
                            endRadius: 72
                        )
                    )
                    .frame(width: 144, height: 144)
                    .blur(radius: 24)

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

// MARK: - Comic Zeal Scrubber
struct ComicZealScrubber: View {
    let onScrub: (String) -> Void
    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ#")
    @State private var activeLetter: String? = nil
    
    var body: some View {
        GeometryReader { geo in
            let itemHeight = geo.size.height / CGFloat(letters.count)
            
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { char in
                    Text(String(char))
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(activeLetter == String(char) ? Theme.blue : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: itemHeight)
                }
            }
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDrag(value: value, itemHeight: itemHeight)
                    }
                    .onEnded { _ in
                        activeLetter = nil
                    }
            )
        }
        .frame(width: 24)
    }
    
    private func handleDrag(value: DragGesture.Value, itemHeight: CGFloat) {
        let index = Int(value.location.y / itemHeight)
        if index >= 0 && index < letters.count {
            let letter = String(letters[index])
            if activeLetter != letter {
                activeLetter = letter
                onScrub(letter)
                let generator = UISelectionFeedbackGenerator()
                generator.selectionChanged()
            }
        }
    }
}

import SwiftUI

/// Master Unified Reader UI Chrome Overlay
/// Shared across Comic, EPUB, PDF, and Webtoon reader engines.
/// Features floating frosted-glass controls, page scrubber, reading mode switcher,
/// and instant access to the System Dictionary & Global Notebook.
struct MasterReaderChromeOverlay: View {
    let title: String
    let subtitle: String?
    let currentPage: Int
    let totalPages: Int
    let isBookmarked: Bool
    
    // Callbacks & Actions
    var onDismiss: () -> Void
    var onScrubToPage: (Int) -> Void
    var onToggleBookmark: () -> Void
    var onOpenDictionary: () -> Void
    var onOpenNotebook: () -> Void
    var onOpenSettings: () -> Void
    
    @State private var isScrubbing = false
    @State private var scrubbedPage: Double = 0
    
    var body: some View {
        VStack {
            // MARK: - Top Floating Glass Bar
            topGlassHeader
                .padding(.top, 8)
                .padding(.horizontal, 16)
            
            Spacer()
            
            // MARK: - Bottom Floating Glass Capsule
            bottomGlassCapsule
                .padding(.bottom, 16)
                .padding(.horizontal, 16)
        }
        .onAppear {
            scrubbedPage = Double(currentPage)
        }
        .onChange(of: currentPage) { _, newPage in
            if !isScrubbing {
                scrubbedPage = Double(newPage)
            }
        }
    }
    
    // MARK: - Top Floating Glass Header
    private var topGlassHeader: some View {
        HStack(spacing: 12) {
            Button(action: {
                triggerHaptic()
                onDismiss()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Circle())
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .foregroundColor(.primary)
                
                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Dictionary Button
            Button(action: {
                triggerHaptic()
                onOpenDictionary()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "character.book.closed.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Look Up")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.15))
                .foregroundColor(.accentColor)
                .clipShape(Capsule())
            }
            
            // Bookmark Toggle
            Button(action: {
                triggerHaptic()
                onToggleBookmark()
            }) {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isBookmarked ? .yellow : .primary)
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Circle())
            }
            
            // Master Settings Button
            Button(action: {
                triggerHaptic()
                onOpenSettings()
            }) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
        )
    }
    
    // MARK: - Bottom Floating Glass Capsule
    private var bottomGlassCapsule: some View {
        VStack(spacing: 12) {
            // Page Scrubber Row
            HStack(spacing: 14) {
                Text("\(Int(scrubbedPage) + 1)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(width: 36, alignment: .trailing)
                
                Slider(
                    value: $scrubbedPage,
                    in: 0...Double(max(0, totalPages - 1)),
                    step: 1
                ) { editing in
                    isScrubbing = editing
                    if !editing {
                        onScrubToPage(Int(scrubbedPage))
                        triggerHaptic()
                    }
                }
                .accentColor(.accentColor)
                
                Text("\(totalPages)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .leading)
            }
            .padding(.horizontal, 8)
            
            Divider()
                .background(Color.primary.opacity(0.1))
            
            // Quick Control Action Items
            HStack {
                // Notebook Trigger
                Button(action: {
                    triggerHaptic()
                    onOpenNotebook()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "note.text")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Notebook")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
                }
                
                Spacer()
                
                // 3D Physical Page Turn Standard Badge
                HStack(spacing: 4) {
                    Image(systemName: "curl.page")
                        .font(.system(size: 13, weight: .bold))
                    Text("3D Physical Curl")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundColor(.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.2), radius: 12, x: 0, y: 6)
        )
    }
    
    private func triggerHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }
}

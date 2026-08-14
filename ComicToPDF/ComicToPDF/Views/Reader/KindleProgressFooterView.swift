import SwiftUI

/// Professional InksyncPro signature progress footer.
/// Floating glassmorphic HUD pill displaying real-time reading progress, pages remaining in current chapter, and estimated reading pace.
struct InksyncProgressFooterView: View {
    let currentPage: Int            // 1-indexed chapter or book page
    let totalPages: Int             // total chapters or total book pages
    var chapterPage: Int = 0        // 0-indexed page inside current chapter
    var chapterTotalPages: Int = 1  // total pages in current chapter
    var chapterTitle: String? = nil // Optional semantic chapter or TOC title (e.g. "Introduction", "Chapter 1")
    var isBookSection: Bool = false // True if dividing an EPUB spine
    let estimatedMinutesLeft: Int?
    var accentColor: Color = Color(hex: "#7B5EA7")
    
    @ObservedObject private var prefs = EBookPreferences.shared
    @Environment(\.colorScheme) private var colorScheme
    
    private var progressPercentage: Int {
        Int((Double(currentPage) / Double(max(1, totalPages))) * 100)
    }
    
    private var sanitizedChapterPage: Int {
        if chapterPage >= 99900 {
            return max(0, chapterTotalPages - 1)
        }
        return min(max(0, chapterPage), max(0, chapterTotalPages - 1))
    }
    
    private var pagesLeftInChapter: Int {
        max(0, chapterTotalPages - (sanitizedChapterPage + 1))
    }
    
    private var primaryText: String {
        let trimmedTitle = chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNamedTitle = (trimmedTitle != nil && !trimmedTitle!.isEmpty)
        
        switch prefs.progressMode {
        case 1:
            // Pages left in chapter / section
            let label = pagesLeftInChapter == 1 ? "1 page left in chapter" : "\(pagesLeftInChapter) pages left in chapter"
            return label
        case 2:
            // Estimated time remaining
            if let mins = estimatedMinutesLeft, mins > 0 {
                return "~\(mins) min\(mins == 1 ? "" : "s") left in book"
            } else {
                return "\(progressPercentage)% completed"
            }
        default:
            // Semantic Chapter Title & Page Indicator
            if let title = trimmedTitle, !title.isEmpty {
                if chapterTotalPages > 1 {
                    return "Page \(sanitizedChapterPage + 1) of \(chapterTotalPages)  ·  \(title)"
                } else {
                    return "\(title)"
                }
            } else if chapterTotalPages > 1 {
                if isBookSection {
                    return "Page \(sanitizedChapterPage + 1) of \(chapterTotalPages)  ·  Section \(currentPage) of \(totalPages)"
                } else {
                    return "Page \(sanitizedChapterPage + 1) of \(chapterTotalPages)"
                }
            } else {
                return "Page \(currentPage) of \(totalPages)"
            }
        }
    }
    
    var body: some View {
        VStack {
            Spacer()
            HStack {
                HStack(spacing: 8) {
                    // Pulsing/glowing active status indicator dot
                    Circle()
                        .fill(accentColor)
                        .frame(width: 5, height: 5)
                        .shadow(color: accentColor.opacity(0.6), radius: 3, x: 0, y: 0)
                    
                    Text(primaryText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.65))
                        .lineLimit(1)
                    
                    if prefs.progressMode != 2 {
                        Text("\(progressPercentage)%")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(accentColor.opacity(0.85))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(prefs.activeTheme.background(colorScheme: colorScheme).opacity(0.85))
                        .background(.ultraThinMaterial, in: Capsule())
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
                .contentShape(Capsule())
                .onTapGesture {
                    HapticEngine.selection()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        prefs.progressMode = (prefs.progressMode + 1) % 3
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
        .ignoresSafeArea()
    }
}

/// Backward compatibility alias for KindleProgressFooterView
typealias KindleProgressFooterView = InksyncProgressFooterView

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
    var tierText: String? = nil     // Discrete Smart Tier/Quadrant indicator (e.g. "Tier 2/4", "Col 1 · Top")
    let estimatedMinutesLeft: Int?
    var accentColor: Color = Color(hex: "#7B5EA7")

    @ObservedObject private var prefs = EBookPreferences.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var isExpanded: Bool = false
    @State private var collapseTask: Task<Void, Never>? = nil

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var isPhoneLandscape: Bool {
        if !isPad {
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene) {
                return scene.interfaceOrientation.isLandscape
            }
        }
        return false
    }

    private var progressPercentage: Int {
        guard totalPages > 0 else { return 0 }
        if isBookSection && chapterTotalPages > 1 {
            let sectionFraction = Double(max(0, currentPage - 1)) / Double(totalPages)
            let pageFraction = (Double(sanitizedChapterPage) / Double(max(1, chapterTotalPages))) / Double(totalPages)
            let total = min(1.0, max(0.0, sectionFraction + pageFraction))
            return Int(total * 100)
        } else {
            let safeCurrent = min(totalPages, max(1, currentPage))
            return Int((Double(safeCurrent) / Double(totalPages)) * 100)
        }
    }

    private var sanitizedChapterPage: Int {
        if chapterPage >= 99900 {
            return max(0, chapterTotalPages - 1)
        }
        return min(max(0, chapterPage), max(0, chapterTotalPages - 1))
    }

    private var pagesLeftInChapter: Int {
        guard chapterTotalPages > 0 else { return 0 }
        return max(0, chapterTotalPages - (sanitizedChapterPage + 1))
    }

    private var pagesLeftInBook: Int {
        guard totalPages > 0 else { return 0 }
        return max(0, totalPages - max(1, currentPage))
    }

    private var condensedText: String {
        let tierSuffix = (tierText != nil && !tierText!.isEmpty) ? " · \(tierText!)" : ""
        switch prefs.progressMode {
        case 1:
            let left = isBookSection && chapterTotalPages > 1 ? pagesLeftInChapter : pagesLeftInBook
            let base = left == 1 ? "1 left" : "\(left) left"
            return "\(base)\(tierSuffix)"
        case 2:
            let base: String
            if let mins = estimatedMinutesLeft, mins > 0 {
                let safeMins = min(mins, 99_999)
                if safeMins < 60 {
                    base = "~\(safeMins)m"
                } else {
                    let hrs = safeMins / 60
                    let rem = safeMins % 60
                    base = rem > 0 ? "~\(hrs)h \(rem)m" : "~\(hrs)h"
                }
            } else {
                base = "\(progressPercentage)%"
            }
            return "\(base)\(tierSuffix)"
        case 3:
            let wpm = prefs.readingSpeedWPM
            let currentWPM = max(50, min(1500, wpm.isFinite && wpm > 0 ? Int(wpm) : 250))
            return "\(currentWPM) WPM\(tierSuffix)"
        default:
            guard totalPages > 0 else { return "Loading..." }
            let basePage: String
            if chapterTotalPages > 1 {
                basePage = "\(sanitizedChapterPage + 1) / \(chapterTotalPages)"
            } else {
                let safePage = min(totalPages, max(1, currentPage))
                basePage = "\(safePage) / \(totalPages)"
            }
            return "\(basePage)\(tierSuffix)"
        }
    }

    private var primaryText: String {
        let trimmedTitle = chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tierSuffix = (tierText != nil && !tierText!.isEmpty) ? " · \(tierText!)" : ""

        switch prefs.progressMode {
        case 1:
            // Mode 1: Pages left
            let base: String
            if isBookSection && chapterTotalPages > 1 {
                let left = pagesLeftInChapter
                if let title = trimmedTitle, !title.isEmpty {
                    base = left == 1 ? "1 page left in \(title)" : "\(left) pages left in \(title)"
                } else {
                    base = left == 1 ? "1 page left in chapter" : "\(left) pages left in chapter"
                }
            } else {
                let left = pagesLeftInBook
                base = left == 1 ? "1 page left in book" : "\(left) pages left in book"
            }
            return "\(base)\(tierSuffix)"
        case 2:
            // Mode 2: Estimated time remaining
            let base: String
            if let mins = estimatedMinutesLeft, mins > 0 {
                let safeMins = min(mins, 99_999)
                if safeMins < 60 {
                    base = "~\(safeMins) min\(safeMins == 1 ? "" : "s") left in book"
                } else {
                    let hrs = safeMins / 60
                    let rem = safeMins % 60
                    base = rem > 0 ? "~\(hrs)h \(rem)m left in book" : "~\(hrs)h left in book"
                }
            } else {
                base = "\(progressPercentage)% completed"
            }
            return "\(base)\(tierSuffix)"
        case 3:
            // Mode 3: Reading Pace WPM & Completion
            let wpm = prefs.readingSpeedWPM
            let currentWPM = max(50, min(1500, wpm.isFinite && wpm > 0 ? Int(wpm) : 250))
            return "\(currentWPM) WPM · Reading Pace\(tierSuffix)"
        default:
            // Mode 0: Semantic Chapter Title & Page Indicator
            guard totalPages > 0 else { return "Loading..." }
            let safePage = min(totalPages, max(1, currentPage))
            if let title = trimmedTitle, !title.isEmpty {
                if chapterTotalPages > 1 {
                    return "Page \(sanitizedChapterPage + 1) of \(chapterTotalPages)\(tierSuffix)  ·  \(title)"
                } else {
                    return "\(title)  ·  Page \(safePage) of \(totalPages)\(tierSuffix)"
                }
            } else if chapterTotalPages > 1 {
                if isBookSection {
                    return "Page \(sanitizedChapterPage + 1) of \(chapterTotalPages)\(tierSuffix)  ·  Section \(safePage) of \(totalPages)"
                } else {
                    return "Page \(sanitizedChapterPage + 1) of \(chapterTotalPages)\(tierSuffix)"
                }
            } else {
                return "Page \(safePage) of \(totalPages)\(tierSuffix)"
            }
        }
    }

    private var isExpandedActive: Bool {
        isExpanded && !isPhoneLandscape
    }

    // MARK: - Subcomponents (iPhone vs iPad Idiom Differentiated)

    private var statusDot: some View {
        let dotSize: CGFloat = isPad
            ? (isExpandedActive ? 7.0 : 5.5)
            : (isExpandedActive ? 5.0 : 4.0)
            
        return Circle()
            .fill(accentColor)
            .frame(width: dotSize, height: dotSize)
            .shadow(color: accentColor.opacity(colorScheme == .dark ? 0.7 : 0.4), radius: isPad ? 4 : 3, x: 0, y: 0)
    }

    private var labelText: some View {
        let title = isExpandedActive ? primaryText : condensedText
        
        // Exact Device Scale: iPhone (11-12pt) vs iPad (14-15.5pt)
        let fontSize: CGFloat = isPad
            ? (isExpandedActive ? 15.5 : 14.0)
            : (isExpandedActive ? 12.0 : 11.0)
            
        let maxW: CGFloat? = isPad
            ? (isExpandedActive ? 540 : nil)
            : (isExpandedActive ? (isPhoneLandscape ? 320 : 250) : nil)
            
        let fgColor = colorScheme == .dark
            ? Color.white.opacity(0.94)
            : Color(hex: "#16161F")

        return Text(title)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(fgColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: maxW, alignment: .leading)
    }

    @ViewBuilder
    private var percentageText: some View {
        if prefs.progressMode != 2 && prefs.progressMode != 3 {
            let fontSize: CGFloat = isPad
                ? (isExpandedActive ? 14.5 : 13.5)
                : (isExpandedActive ? 11.0 : 10.0)
                
            Text("\(progressPercentage)%")
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(accentColor.opacity(colorScheme == .dark ? 0.95 : 1.0))
        }
    }

    private var pillBorderGradient: LinearGradient {
        let c1 = colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.12)
        let c2 = colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)
        return LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var pillBackground: some View {
        let innerTint = colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.65)
        return Capsule()
            .fill(.ultraThinMaterial)
            .overlay(Capsule().fill(innerTint))
    }

    private var pillBorder: some View {
        Capsule().strokeBorder(pillBorderGradient, lineWidth: 0.6)
    }

    private var visiblePill: some View {
        // Ergonomic padding calibrated for touch targets and visual proportion
        let hPad: CGFloat = isPad
            ? (isExpandedActive ? 18 : 13)
            : (isExpandedActive ? 13 : 9.5)
            
        let vPad: CGFloat = isPad
            ? (isExpandedActive ? 9.5 : 7.0)
            : (isExpandedActive ? 6.0 : 4.5)
            
        let spacing: CGFloat = isPad
            ? (isExpandedActive ? 10 : 8)
            : (isExpandedActive ? 7 : 5)
            
        let shadowColor = Color.black.opacity(colorScheme == .dark ? 0.32 : 0.08)
        let shadowRadius: CGFloat = isPad ? 12 : 8
        let shadowY: CGFloat = isPad ? 3 : 2

        return HStack(spacing: spacing) {
            statusDot
            labelText
            percentageText
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .background(pillBackground)
        .overlay(pillBorder)
        .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
        .opacity(isExpanded ? 1.0 : 0.85)
        .contentShape(Capsule())
        .onTapGesture {
            triggerModeCycle()
        }
        .onLongPressGesture {
            HapticEngine.medium()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                isExpanded.toggle()
            }
        }
    }

    var body: some View {
        VStack {
            Spacer()
            HStack {
                if prefs.progressMode == ReadingProgressMode.hidden.rawValue || prefs.progressMode == 4 {
                    // Invisible tap zone calibrated for thumb on iPhone vs finger/pencil on iPad
                    Color.clear
                        .frame(width: isPad ? 220 : 140, height: isPad ? 54 : 44)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            HapticEngine.selection()
                            triggerModeCycle()
                        }
                } else {
                    visiblePill
                }

                Spacer()
            }
            .padding(.horizontal, isPad ? 28 : 16)
        }
        .padding(.bottom, isPad ? 14 : (isPhoneLandscape ? 4 : 8))
        .onDisappear {
            collapseTask?.cancel()
            collapseTask = nil
        }
    }

    private func triggerModeCycle() {
        HapticEngine.selection()
        collapseTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            prefs.progressMode = max(0, prefs.progressMode + 1) % 5
            isExpanded = true
        }
        // Auto-condense back to compact pill after 3.2 seconds
        collapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                isExpanded = false
            }
        }
    }
}

/// Backward compatibility alias for KindleProgressFooterView
typealias KindleProgressFooterView = InksyncProgressFooterView

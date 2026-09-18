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

    @State private var isExpanded: Bool = false
    @State private var collapseTask: Task<Void, Never>? = nil

    private var isPhoneLandscape: Bool {
        if UIDevice.current.userInterfaceIdiom == .phone {
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
        switch prefs.progressMode {
        case 1:
            let left = isBookSection && chapterTotalPages > 1 ? pagesLeftInChapter : pagesLeftInBook
            return left == 1 ? "1 left" : "\(left) left"
        case 2:
            if let mins = estimatedMinutesLeft, mins > 0 {
                let safeMins = min(mins, 99_999)
                if safeMins < 60 {
                    return "~\(safeMins)m"
                } else {
                    let hrs = safeMins / 60
                    let rem = safeMins % 60
                    return rem > 0 ? "~\(hrs)h \(rem)m" : "~\(hrs)h"
                }
            } else {
                return "\(progressPercentage)%"
            }
        case 3:
            let wpm = prefs.readingSpeedWPM
            let currentWPM = max(50, min(1500, wpm.isFinite && wpm > 0 ? Int(wpm) : 250))
            return "\(currentWPM) WPM"
        default:
            guard totalPages > 0 else { return "Loading..." }
            if chapterTotalPages > 1 {
                return "\(sanitizedChapterPage + 1) / \(chapterTotalPages)"
            } else {
                let safePage = min(totalPages, max(1, currentPage))
                return "\(safePage) / \(totalPages)"
            }
        }
    }

    private var primaryText: String {
        let trimmedTitle = chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch prefs.progressMode {
        case 1:
            // Mode 1: Pages left
            if isBookSection && chapterTotalPages > 1 {
                let left = pagesLeftInChapter
                if let title = trimmedTitle, !title.isEmpty {
                    return left == 1 ? "1 page left in \(title)" : "\(left) pages left in \(title)"
                } else {
                    return left == 1 ? "1 page left in chapter" : "\(left) pages left in chapter"
                }
            } else {
                let left = pagesLeftInBook
                return left == 1 ? "1 page left in book" : "\(left) pages left in book"
            }
        case 2:
            // Mode 2: Estimated time remaining
            if let mins = estimatedMinutesLeft, mins > 0 {
                let safeMins = min(mins, 99_999)
                if safeMins < 60 {
                    return "~\(safeMins) min\(safeMins == 1 ? "" : "s") left in book"
                } else {
                    let hrs = safeMins / 60
                    let rem = safeMins % 60
                    return rem > 0 ? "~\(hrs)h \(rem)m left in book" : "~\(hrs)h left in book"
                }
            } else {
                return "\(progressPercentage)% completed"
            }
        case 3:
            // Mode 3: Reading Pace WPM & Completion
            let wpm = prefs.readingSpeedWPM
            let currentWPM = max(50, min(1500, wpm.isFinite && wpm > 0 ? Int(wpm) : 250))
            return "\(currentWPM) WPM · Reading Pace"
        default:
            // Mode 0: Semantic Chapter Title & Page Indicator
            guard totalPages > 0 else { return "Loading..." }
            let safePage = min(totalPages, max(1, currentPage))
            if let title = trimmedTitle, !title.isEmpty {
                if chapterTotalPages > 1 {
                    return "Page \(sanitizedChapterPage + 1) of \(chapterTotalPages)  ·  \(title)"
                } else {
                    return "\(title)  ·  Page \(safePage) of \(totalPages)"
                }
            } else if chapterTotalPages > 1 {
                if isBookSection {
                    return "Page \(sanitizedChapterPage + 1) of \(chapterTotalPages)  ·  Section \(safePage) of \(totalPages)"
                } else {
                    return "Page \(sanitizedChapterPage + 1) of \(chapterTotalPages)"
                }
            } else {
                return "Page \(safePage) of \(totalPages)"
            }
        }
    }

    private var isExpandedActive: Bool {
        isExpanded && !isPhoneLandscape
    }

    private var statusDot: some View {
        let dotSize: CGFloat = isExpandedActive ? 5 : 4
        return Circle()
            .fill(accentColor)
            .frame(width: dotSize, height: dotSize)
            .shadow(color: accentColor.opacity(0.6), radius: 3, x: 0, y: 0)
    }

    private var labelText: some View {
        let title = isExpandedActive ? primaryText : condensedText
        let fontSize: CGFloat = isExpandedActive ? 11 : 10
        let maxW: CGFloat? = isExpandedActive ? 240 : nil
        let fgColor = colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.85)

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
            let fontSize: CGFloat = isExpandedActive ? 10 : 9.5
            Text("\(progressPercentage)%")
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(accentColor.opacity(0.95))
        }
    }

    private var pillBorderGradient: LinearGradient {
        let c1 = colorScheme == .dark ? Color.white.opacity(0.25) : Color.white.opacity(0.65)
        let c2 = colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.08)
        return LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var pillBackground: some View {
        let innerTint = colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.03)
        return Capsule()
            .fill(.ultraThinMaterial)
            .overlay(Capsule().fill(innerTint))
    }

    private var pillBorder: some View {
        Capsule().strokeBorder(pillBorderGradient, lineWidth: 0.5)
    }

    private var visiblePill: some View {
        let hPad: CGFloat = isExpandedActive ? 13 : 9
        let vPad: CGFloat = isExpandedActive ? 6 : 4
        let shadowColor = Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08)

        return HStack(spacing: isExpandedActive ? 7 : 5) {
            statusDot
            labelText
            percentageText
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .background(pillBackground)
        .overlay(pillBorder)
        .shadow(color: shadowColor, radius: 8, x: 0, y: 2)
        .opacity(isExpanded ? 1.0 : 0.82)
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
                    // Invisible tap zone so tapping unhides the tracker
                    Color.clear
                        .frame(width: 140, height: 44)
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
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 6)
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

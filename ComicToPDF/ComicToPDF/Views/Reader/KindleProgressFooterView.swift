import SwiftUI

/// Minimal, elegant Kindle-style progress footer displayed at the bottom of the screen.
/// Cycles through progress modes on tap:
/// Mode 0: Page / Total Page (e.g. "Page 42 of 120")
/// Mode 1: Percentage (e.g. "35% complete")
/// Mode 2: Time Remaining in Book (e.g. "18 mins left in book • 35%")
struct KindleProgressFooterView: View {
    let currentPage: Int
    let totalPages: Int
    let estimatedMinutesLeft: Int?
    @ObservedObject private var prefs = EBookPreferences.shared
    
    var progressText: String {
        let pct = Int(Double(currentPage) / Double(max(1, totalPages)) * 100)
        switch prefs.progressMode {
        case 1:
            return "\(pct)% read"
        case 2:
            if let mins = estimatedMinutesLeft, mins > 0 {
                return "\(mins) mins left in book • \(pct)%"
            } else {
                return "\(pct)% read"
            }
        default:
            return "Page \(currentPage) of \(totalPages) • \(pct)%"
        }
    }
    
    var body: some View {
        VStack {
            Spacer()
            HStack {
                Text(progressText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(prefs.activeTheme == .dark ? Color.white.opacity(0.45) : Color.black.opacity(0.45))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        HapticEngine.selection()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            prefs.progressMode = (prefs.progressMode + 1) % 3
                        }
                    }
                Spacer()
            }
        }
        .padding(.bottom, 6)
        .ignoresSafeArea()
    }
}

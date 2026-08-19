import SwiftUI

// MARK: - Next Sequential Issue Descriptor

struct NextIssueInfo: Sendable, Identifiable {
    let id = UUID()
    let fileURL: URL
    let issueTitle: String
    let issueNumber: String
    
    init(fileURL: URL, issueTitle: String, issueNumber: String) {
        self.fileURL = fileURL
        self.issueTitle = issueTitle
        self.issueNumber = issueNumber
    }
}

// MARK: - Next Issue & End-of-Volume Continuity Card

/// Glassmorphic end-of-volume continuity card presented upon reaching the final page of an issue.
/// Displays ComicInfo metadata, completion badges, rating prompt, and single-tap next issue transition.
struct NextIssueCardView: View {
    let comicInfo: ComicInfoParser.ComicInfo?
    let currentFileName: String
    let nextIssue: NextIssueInfo?
    var onOpenNextIssue: (NextIssueInfo) -> Void
    var onReturnToLibrary: () -> Void
    
    @State private var userRating: Int = 5
    
    init(
        comicInfo: ComicInfoParser.ComicInfo?,
        currentFileName: String,
        nextIssue: NextIssueInfo? = nil,
        onOpenNextIssue: @escaping (NextIssueInfo) -> Void,
        onReturnToLibrary: @escaping () -> Void
    ) {
        self.comicInfo = comicInfo
        self.currentFileName = currentFileName
        self.nextIssue = nextIssue
        self.onOpenNextIssue = onOpenNextIssue
        self.onReturnToLibrary = onReturnToLibrary
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Header Badge
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.inkGreen)
                    .font(.system(size: 20))
                
                Text("Issue Completed")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(.top, 8)
            
            // Comic Series / Title Info
            VStack(spacing: 4) {
                Text(comicInfo?.series ?? currentFileName)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.inkTextPrimary)
                    .multilineTextAlignment(.center)
                
                if let num = comicInfo?.number {
                    Text("Issue #\(num)")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.inkViolet)
                }
                
                if let writer = comicInfo?.writer, !writer.isEmpty {
                    Text("Written by \(writer)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.inkTextSecondary)
                }
            }
            
            // Summary Quote (if available)
            if let summary = comicInfo?.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.inkTextSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            
            // 5-Star Rating Prompt
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        HapticEngine.selection()
                        userRating = star
                    } label: {
                        Image(systemName: star <= userRating ? "star.fill" : "star")
                            .font(.system(size: 18))
                            .foregroundColor(star <= userRating ? .inkAmber : .inkTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            
            Divider()
                .background(Color.primary.opacity(0.12))
            
            // Next Issue or Library Action Buttons
            VStack(spacing: 10) {
                if let next = nextIssue {
                    Button {
                        HapticEngine.success()
                        onOpenNextIssue(next)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 16, weight: .bold))
                            Text("Read Next: \(next.issueTitle)")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.inkViolet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                
                Button {
                    HapticEngine.light()
                    onReturnToLibrary()
                } label: {
                    Text("Return to Library")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.inkTextSecondary)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
        .padding(20)
        .frame(maxWidth: 380)
        .background(Color.inkSurfaceRaised.opacity(0.95).background(.ultraThinMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 20, y: 10)
    }
}

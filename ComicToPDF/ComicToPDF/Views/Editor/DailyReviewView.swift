import SwiftUI
import SwiftData

// MARK: - DailyReviewView
// Readwise-parity spaced repetition review.
// SM-2 algorithm is already wired on SDAnnotation (easeFactor, reviewCount, nextReviewDate).
// This view upgrades the UX: streak header, progress bar, "Again" re-queue, interval preview.

struct DailyReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<SDAnnotation> { $0.kindRaw == "highlight" },
           sort: \SDAnnotation.nextReviewDate, order: .forward)
    private var allHighlights: [SDAnnotation]

    @State private var reviewQueue: [SDAnnotation] = []
    @State private var currentIndex: Int = 0
    @State private var showFront: Bool = true
    @State private var showComplete: Bool = false
    @State private var sessionReviewedCount: Int = 0
    @State private var earnedStreak: Int = 0

    // Precomputed interval for the current card (shown as hint before rating)
    @State private var previewIntervals: (again: Double, hard: Double, good: Double, easy: Double) = (1, 2, 4, 7)

    var body: some View {
        NavigationStack {
            ZStack {
                Color.inkBackground.ignoresSafeArea()

                if showComplete {
                    completionView
                } else if reviewQueue.isEmpty {
                    emptyStateView
                } else if currentIndex < reviewQueue.count {
                    VStack(spacing: 0) {
                        progressBar
                        reviewCard(for: reviewQueue[currentIndex])
                    }
                }
            }
            .navigationTitle("Daily Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Color.inkTextSecondary)
                }
                ToolbarItem(placement: .principal) {
                    streakBadge
                }
            }
            .onAppear { buildQueue() }
        }
    }

    // MARK: - Header Components

    private var streakBadge: some View {
        let streak = ReviewStreakTracker.shared.currentStreak
        return HStack(spacing: 4) {
            if streak > 0 {
                Text("🔥")
                    .font(.system(size: 14))
                Text("\(streak)-day streak")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.inkAccentNavigation)
            } else {
                Text("Daily Review")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.inkTextPrimary)
            }
        }
    }

    private var progressBar: some View {
        let total = reviewQueue.count
        let done  = min(currentIndex, total)
        let progress = total > 0 ? CGFloat(done) / CGFloat(total) : 0

        return VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.inkBorderSubtle)
                        .frame(height: 3)
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.inkAccentKnowledge, Color.inkBlue],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * progress, height: 3)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: progress)
                }
            }
            .frame(height: 3)

            HStack {
                Text("\(done) of \(total)")
                    .font(.caption)
                    .foregroundStyle(Color.inkTextTertiary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
        }
    }

    // MARK: - Review Card

    @ViewBuilder
    private func reviewCard(for annotation: SDAnnotation) -> some View {
        VStack {
            Spacer()

            // Card
            VStack(alignment: .leading, spacing: 16) {
                // Source label
                if let bookTitle = annotation.readwiseBookTitle ?? annotation.chapterTitle {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color(hex: annotation.colorHex ?? "#FFD60A"))
                            .frame(width: 3, height: 14)
                        Text(bookTitle)
                            .font(.caption.bold())
                            .foregroundStyle(Color.inkAccentKnowledge)
                            .lineLimit(1)
                    }
                }

                // Highlight text
                Text(annotation.selectedText ?? "No text")
                    .font(.system(size: 17, weight: .regular, design: .serif))
                    .lineSpacing(7)
                    .foregroundStyle(Color.inkTextPrimary)

                // Flip reveal
                if !showFront {
                    Divider()
                        .background(Color.inkBorderSubtle)

                    if let note = annotation.noteText, !note.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(Color.inkAccentKnowledge)
                            Text(note)
                                .font(.callout)
                                .foregroundStyle(Color.inkTextSecondary)
                        }
                    } else {
                        Text("No note attached.")
                            .font(.callout)
                            .foregroundStyle(Color.inkTextTertiary)
                            .italic()
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .inkCard(radius: 18)
            .padding(.horizontal, 20)

            Spacer()

            // Controls
            if showFront {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showFront = false
                        updateIntervalPreview(for: annotation)
                    }
                } label: {
                    Text("Show Details")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                        .background(Color.inkSurfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(Color.inkTextPrimary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5)
                        )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
            } else {
                // Interval hint
                VStack(spacing: 12) {
                    Text("How well did you remember this?")
                        .font(.caption)
                        .foregroundStyle(Color.inkTextTertiary)

                    HStack(spacing: 10) {
                        ratingButton(
                            title: "Again",
                            subtitle: ReviewStreakTracker.intervalDescription(days: previewIntervals.again),
                            color: .orange
                        ) { submitReview(annotation: annotation, quality: 0) }

                        ratingButton(
                            title: "Hard",
                            subtitle: ReviewStreakTracker.intervalDescription(days: previewIntervals.hard),
                            color: .red
                        ) { submitReview(annotation: annotation, quality: 2) }

                        ratingButton(
                            title: "Good",
                            subtitle: ReviewStreakTracker.intervalDescription(days: previewIntervals.good),
                            color: .green
                        ) { submitReview(annotation: annotation, quality: 4) }

                        ratingButton(
                            title: "Easy",
                            subtitle: ReviewStreakTracker.intervalDescription(days: previewIntervals.easy),
                            color: Color.inkBlue
                        ) { submitReview(annotation: annotation, quality: 5) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    private func ratingButton(title: String, subtitle: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(color)
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.inkTextTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(color.opacity(0.25), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Completion

    private var completionView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Glow icon
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(colors: [Color.green.opacity(0.3), .clear]),
                        center: .center, startRadius: 20, endRadius: 70
                    ))
                    .frame(width: 140, height: 140)
                    .blur(radius: 20)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.green)
            }

            VStack(spacing: 8) {
                Text("Session Complete!")
                    .font(.title2.bold())
                    .foregroundStyle(Color.inkTextPrimary)

                Text("Reviewed \(sessionReviewedCount) cards")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkTextSecondary)

                if earnedStreak > 0 {
                    HStack(spacing: 4) {
                        Text("🔥")
                        Text("\(earnedStreak)-day streak")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.inkAccentNavigation)
                    }
                    .padding(.top, 4)
                }
            }

            let total = ReviewStreakTracker.shared.totalCardsReviewed
            Text("\(total) cards reviewed total")
                .font(.caption)
                .foregroundStyle(Color.inkTextTertiary)

            Button("Done") { dismiss() }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(
                    LinearGradient(
                        colors: [Color.inkAccentKnowledge, Color.inkBlue],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 40)
                .shadow(color: Color.inkAccentKnowledge.opacity(0.35), radius: 10, y: 4)

            Spacer()
        }
        .padding()
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical")
                .font(.system(size: 60))
                .foregroundStyle(Color.inkTextTertiary)
            Text("All caught up!")
                .font(.title2.bold())
                .foregroundStyle(Color.inkTextPrimary)
            Text("No highlights are due for review today.\nKeep reading to build your queue.")
                .font(.subheadline)
                .foregroundStyle(Color.inkTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - Logic

    private func buildQueue() {
        let now = Date()
        let due = allHighlights.filter { $0.nextReviewDate == nil || $0.nextReviewDate! <= now }
        reviewQueue = Array(due.shuffled().prefix(10))
    }

    private func updateIntervalPreview(for annotation: SDAnnotation) {
        previewIntervals = (
            again: 1,                                          // quality 0: reset to 1 day
            hard:  computeInterval(annotation: annotation, quality: 2),
            good:  computeInterval(annotation: annotation, quality: 4),
            easy:  computeInterval(annotation: annotation, quality: 5)
        )
    }

    private func computeInterval(annotation: SDAnnotation, quality: Int) -> Double {
        let newEase = max(1.3, annotation.easeFactor + (0.1 - Double(5 - quality) * (0.08 + Double(5 - quality) * 0.02)))
        let count = annotation.reviewCount + 1
        if count == 1 { return 1 }
        if count == 2 { return 6 }
        return round(Double(count - 1) * newEase)
    }

    private func submitReview(annotation: SDAnnotation, quality: Int) {
        if quality == 0 {
            // "Again" — Readwise behavior: re-queue at end of session, don't advance date
            withAnimation {
                let card = reviewQueue[currentIndex]
                reviewQueue.remove(at: currentIndex)
                reviewQueue.append(card)
                showFront = true
                // Don't advance currentIndex — next card is now at same index
                if currentIndex >= reviewQueue.count { currentIndex = 0 }
            }
            return
        }

        // SM-2 update
        annotation.reviewCount += 1
        let newEase = annotation.easeFactor + (0.1 - Double(5 - quality) * (0.08 + Double(5 - quality) * 0.02))
        annotation.easeFactor = max(1.3, newEase)

        let interval: Double
        if annotation.reviewCount == 1 { interval = 1 }
        else if annotation.reviewCount == 2 { interval = 6 }
        else { interval = round(Double(annotation.reviewCount - 1) * annotation.easeFactor) }

        annotation.nextReviewDate = Date().addingTimeInterval(interval * 24 * 60 * 60)
        try? modelContext.save()

        sessionReviewedCount += 1

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            currentIndex += 1
            showFront = true
            if currentIndex >= reviewQueue.count {
                // Session complete — record streak
                earnedStreak = ReviewStreakTracker.shared.recordSessionCompleted(cardCount: sessionReviewedCount)
                showComplete = true
            }
        }
    }
}

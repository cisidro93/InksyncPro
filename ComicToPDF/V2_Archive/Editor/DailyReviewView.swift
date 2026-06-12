import SwiftUI
import SwiftData
import PencilKit

// MARK: - PKDrawingView
struct PKDrawingView: UIViewRepresentable {
    let drawingData: Data

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.isUserInteractionEnabled = false
        canvas.backgroundColor = .clear
        if let drawing = try? PKDrawing(data: drawingData) {
            canvas.drawing = drawing
        }
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        if let drawing = try? PKDrawing(data: drawingData) {
            uiView.drawing = drawing
        }
    }
}

// MARK: - DailyReviewView
// Customized spaced repetition review deck.
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

    // Tinder drag offset and flip tracking
    @State private var cardDragOffset: CGSize = .zero
    @State private var isTransitioning = false

    // Precomputed interval for the current card (shown on detail review)
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
                        
                        Spacer()
                        
                        cardDeck
                        
                        Spacer()
                        
                        // Action/Info bottom indicator
                        HStack {
                            Spacer()
                            VStack(spacing: 4) {
                                Image(systemName: "hand.draw")
                                    .font(.caption2)
                                    .foregroundStyle(Color.inkTextTertiary)
                                Text("Swipe Left for Again • Swipe Right for Good")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.inkTextTertiary)
                            }
                            Spacer()
                        }
                        .padding(.bottom, 24)
                        .opacity(showFront ? 0.6 : 0.2)
                    }
                }
            }
            .navigationTitle("Zettel Review")
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

    // MARK: - Tinder Deck

    private var cardDeck: some View {
        ZStack {
            // Next card underneath (visual depth preview)
            if currentIndex + 1 < reviewQueue.count {
                reviewCardContent(for: reviewQueue[currentIndex + 1])
                    .scaleEffect(0.95)
                    .offset(y: 12)
                    .opacity(0.45)
                    .blur(radius: 0.8)
                    .disabled(true)
            }

            // Top active card
            if currentIndex < reviewQueue.count {
                reviewCardContent(for: reviewQueue[currentIndex])
                    .offset(x: cardDragOffset.width, y: cardDragOffset.height * 0.4)
                    .rotationEffect(.degrees(Double(cardDragOffset.width / 12)))
                    .shadow(color: Color.black.opacity(min(0.15, 0.05 + abs(Double(cardDragOffset.width / 1000)))), radius: 10, y: 5)
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                guard !isTransitioning else { return }
                                cardDragOffset = gesture.translation
                            }
                            .onEnded { gesture in
                                guard !isTransitioning else { return }
                                let width = gesture.translation.width
                                if width > 120 {
                                    // Swipe right -> Good (quality 4)
                                    isTransitioning = true
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        cardDragOffset = CGSize(width: 500, height: gesture.translation.height)
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        submitReview(annotation: reviewQueue[currentIndex], quality: 4)
                                        cardDragOffset = .zero
                                        isTransitioning = false
                                    }
                                } else if width < -120 {
                                    // Swipe left -> Again (quality 0)
                                    isTransitioning = true
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        cardDragOffset = CGSize(width: -500, height: gesture.translation.height)
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        submitReview(annotation: reviewQueue[currentIndex], quality: 0)
                                        cardDragOffset = .zero
                                        isTransitioning = false
                                    }
                                } else {
                                    // Snap back
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                        cardDragOffset = .zero
                                    }
                                }
                            }
                    )
            }
        }
        .padding(.horizontal, 20)
    }

    private func reviewCardContent(for annotation: SDAnnotation) -> some View {
        ZStack {
            if showFront {
                cardFrontView(for: annotation)
            } else {
                cardBackView(for: annotation)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 380)
        .background(Color.inkSurfaceRaised)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5)
        )
        .rotation3DEffect(
            .degrees(showFront ? 0 : 180),
            axis: (x: 0.0, y: 1.0, z: 0.0)
        )
        .overlay(swipeOverlayBadges)
    }

    private var swipeOverlayBadges: some View {
        GeometryReader { geo in
            ZStack {
                if cardDragOffset.width > 20 {
                    Text("KEEP GOOD")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(Color.green, lineWidth: 1.5))
                        .rotationEffect(.degrees(-15))
                        .opacity(Double(min(1.0, (cardDragOffset.width - 20) / 60)))
                        .position(x: 70, y: 50)
                } else if cardDragOffset.width < -20 {
                    Text("REVIEW AGAIN")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(Color.orange, lineWidth: 1.5))
                        .rotationEffect(.degrees(15))
                        .opacity(Double(min(1.0, (-cardDragOffset.width - 20) / 60)))
                        .position(x: geo.size.width - 80, y: 50)
                }
            }
        }
    }

    // MARK: - Card Sides

    private func cardFrontView(for annotation: SDAnnotation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: source details
            if let bookTitle = annotation.readwiseBookTitle ?? annotation.chapterTitle {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(hex: annotation.colorHex ?? "#FFD60A"))
                        .frame(width: 3, height: 14)
                    Text(bookTitle)
                        .font(.caption.bold())
                        .foregroundStyle(Color.inkAccentKnowledge)
                        .lineLimit(1)
                    Spacer()
                    Text("p. \(annotation.pageIndex + 1)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.inkTextTertiary)
                }
            }

            // Body Highlight content
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let text = annotation.selectedText, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 17, weight: .regular, design: .serif))
                            .lineSpacing(6)
                            .foregroundStyle(Color.inkTextPrimary)
                            .multilineTextAlignment(.leading)
                    }

                    if let drawData = annotation.drawingData {
                        PKDrawingView(drawingData: drawData)
                            .frame(height: 120)
                            .background(Color.inkBackground.opacity(0.3))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                    }

                    if let ocrText = annotation.drawingOCRText, !ocrText.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "scribble")
                                .font(.caption2)
                                .foregroundStyle(Color.inkTextTertiary)
                                .padding(.top, 2)
                            Text(ocrText)
                                .font(.system(size: 14, weight: .regular, design: .serif))
                                .italic()
                                .foregroundStyle(Color.inkTextSecondary)
                                .lineSpacing(4)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Label("Tap to Reveal details", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.inkTextTertiary)
                Spacer()
            }
        }
        .padding(24)
        .contentShape(Rectangle())
        .onTapGesture { flipCard() }
    }

    private func cardBackView(for annotation: SDAnnotation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Notes & Reference")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.inkAccentKnowledge)

            // Note Text Box
            VStack(alignment: .leading, spacing: 8) {
                if let note = annotation.noteText, !note.isEmpty {
                    Label("My Thoughts", systemImage: "pencil.line")
                        .font(.caption.bold())
                        .foregroundStyle(Color.inkTextSecondary)
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(Color.inkTextPrimary)
                        .lineLimit(4)
                } else {
                    Text("No comments attached to this highlight.")
                        .font(.callout)
                        .italic()
                        .foregroundStyle(Color.inkTextTertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.inkBackground.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            // Tags List
            let tags = annotation.tags ?? []
            if !tags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tags")
                        .font(.caption.bold())
                        .foregroundStyle(Color.inkTextSecondary)
                    HStack(spacing: 6) {
                        ForEach(tags.prefix(4), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.inkAccentKnowledge)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.inkAccentKnowledge.opacity(0.1), in: Capsule())
                        }
                    }
                }
            }

            Spacer()

            // Micro adjustments
            VStack(spacing: 8) {
                Text("Rate Retention (Failsafe controls)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.inkTextTertiary)

                HStack(spacing: 8) {
                    miniRatingButton(title: "Again", color: .orange) {
                        submitReview(annotation: annotation, quality: 0)
                    }
                    miniRatingButton(title: "Hard", color: .red) {
                        submitReview(annotation: annotation, quality: 2)
                    }
                    miniRatingButton(title: "Good", color: .green) {
                        submitReview(annotation: annotation, quality: 4)
                    }
                    miniRatingButton(title: "Easy", color: Color.inkBlue) {
                        submitReview(annotation: annotation, quality: 5)
                    }
                }
            }
            .onTapGesture { /* consume tap */ }
        }
        .padding(24)
        .contentShape(Rectangle())
        .onTapGesture { flipCard() }
    }

    private func miniRatingButton(title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(color.opacity(0.25), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func flipCard() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            showFront.toggle()
        }
    }

    // MARK: - Logic

    private func buildQueue() {
        let now = Date()
        let due = allHighlights.filter { $0.nextReviewDate == nil || $0.nextReviewDate! <= now }
        reviewQueue = Array(due.shuffled().prefix(10))
    }

    private func updateIntervalPreview(for annotation: SDAnnotation) {
        previewIntervals = (
            again: 1,
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
            // "Again" — re-queue at end of session, don't advance date
            withAnimation {
                let card = reviewQueue[currentIndex]
                reviewQueue.remove(at: currentIndex)
                reviewQueue.append(card)
                showFront = true
                if currentIndex >= reviewQueue.count { currentIndex = 0 }
            }
            return
        }

        // SM-2 algorithm update
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

    // MARK: - Completion View with Ink-Droplet Heatmap

    private var completionView: some View {
        VStack(spacing: 20) {
            Spacer()

            // Flame emoji and streak header
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(colors: [Color.inkAccentNavigation.opacity(0.2), .clear]),
                        center: .center, startRadius: 10, endRadius: 60
                    ))
                    .frame(width: 120, height: 120)
                    .blur(radius: 15)

                Text("🔥")
                    .font(.system(size: 64))
            }

            VStack(spacing: 6) {
                Text("Review Session Done!")
                    .font(.title3.bold())
                    .foregroundStyle(Color.inkTextPrimary)

                Text("Reviewed \(sessionReviewedCount) highlights today")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkTextSecondary)

                if earnedStreak > 0 {
                    Text("\(earnedStreak)-day streak active")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.inkAccentNavigation)
                        .padding(.top, 2)
                }
            }

            // Custom Ink-Droplet Heatmap
            inkDropletHeatmap

            Button("Done") { dismiss() }
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(15)
                .background(
                    LinearGradient(
                        colors: [Color.inkAccentKnowledge, Color.inkBlue],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 48)
                .shadow(color: Color.inkAccentKnowledge.opacity(0.3), radius: 8, y: 4)

            Spacer()
        }
        .padding()
    }

    private var heatmapCells: [Date] {
        let calendar = Calendar.current
        var dates: [Date] = []
        let today = calendar.startOfDay(for: Date())
        for dayOffset in (0..<28).reversed() {
            if let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) {
                dates.append(date)
            }
        }
        return dates
    }

    private var inkDropletHeatmap: some View {
        VStack(spacing: 10) {
            Text("Mind Palace Ink Droplets (Past 4 Weeks)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.inkTextTertiary)
                .tracking(0.8)

            let history = ReviewStreakTracker.shared.reviewHistory
            let cells = heatmapCells
            let df: DateFormatter = {
                let d = DateFormatter()
                d.dateFormat = "yyyy-MM-dd"
                return d
            }()

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 8) {
                ForEach(cells, id: \.self) { date in
                    let key = df.string(from: date)
                    let count = history[key] ?? 0
                    
                    ZStack {
                        if count == 0 {
                            Circle()
                                .stroke(Color.inkBorderSubtle, lineWidth: 1)
                                .frame(width: 10, height: 10)
                        } else {
                            let size = CGFloat(min(16.0, 10.0 + Double(count) * 0.8))
                            let opacity = min(1.0, 0.4 + Double(count) * 0.1)
                            
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [Color.inkAccentKnowledge, Color.inkBlue],
                                        center: .center, startRadius: 0, endRadius: size / 2
                                    )
                                )
                                .opacity(opacity)
                                .frame(width: size, height: size)
                                .shadow(color: Color.inkAccentKnowledge.opacity(0.3), radius: 2)
                        }
                    }
                    .frame(width: 18, height: 18)
                }
            }
            .frame(width: 170)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5))
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 52))
                .foregroundStyle(Color.inkTextTertiary)
            Text("All reviewed!")
                .font(.title3.bold())
                .foregroundStyle(Color.inkTextPrimary)
            Text("No highlights are due for review today.\nKeep reading to build your inbox queue.")
                .font(.subheadline)
                .foregroundStyle(Color.inkTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

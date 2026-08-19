import SwiftUI

// MARK: - Active Recall Spaced Repetition Review Deck View

/// 120Hz ProMotion active recall review experience with 3D card flips, Tinder swipe gestures, and live cloze deletion reveals.
public struct StudyDeckReviewView: View {
    @Environment(\.dismiss) private var dismiss
    
    let reviewCards: [StudyCard]
    var onSessionCompleted: ((Int) -> Void)? = nil
    
    @State private var currentIndex: Int = 0
    @State private var isAnswerRevealed: Bool = false
    @State private var dragOffset: CGSize = .zero
    @State private var isSessionComplete: Bool = false
    @State private var reviewedCount: Int = 0
    @State private var againCount: Int = 0
    @State private var goodCount: Int = 0
    
    private let scheduler = StudyCardScheduler.shared
    private let clozeParser = ClozeDeletionParser.shared
    private let store = StudyNotebookStore.shared
    
    public init(
        reviewCards: [StudyCard],
        onSessionCompleted: ((Int) -> Void)? = nil
    ) {
        self.reviewCards = reviewCards
        self.onSessionCompleted = onSessionCompleted
    }
    
    private var currentCard: StudyCard? {
        guard currentIndex < reviewCards.count else { return nil }
        return reviewCards[currentIndex]
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                Color.inkBackground
                    .ignoresSafeArea()
                
                if isSessionComplete || reviewCards.isEmpty {
                    sessionCompleteView
                } else if let card = currentCard {
                    VStack(spacing: 0) {
                        // Header Progress Bar
                        progressBarView
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                        
                        Spacer()
                        
                        // Interactive Flashcard Stack
                        flashcardStackView(card: card)
                            .frame(maxWidth: 520, maxHeight: 420)
                            .padding(.horizontal, 20)
                        
                        Spacer()
                        
                        // Spaced Repetition Rating Action Bar
                        ratingActionBar(card: card)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Study Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundColor(.inkTextSecondary)
                }
                
                ToolbarItem(placement: .principal) {
                    if !reviewCards.isEmpty && !isSessionComplete {
                        Text("\(currentIndex + 1) of \(reviewCards.count)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.inkTextPrimary)
                    }
                }
            }
        }
    }
    
    // MARK: - Progress Bar
    
    private var progressBarView: some View {
        let total = reviewCards.count
        let progress = total > 0 ? CGFloat(currentIndex) / CGFloat(total) : 0
        
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 6)
                
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.inkViolet, .inkBlue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(6, geo.size.width * progress), height: 6)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: progress)
            }
        }
        .frame(height: 6)
    }
    
    // MARK: - Flashcard Stack View
    
    private func flashcardStackView(card: StudyCard) -> some View {
        let swipeThreshold: CGFloat = 110.0
        
        return ZStack {
            // Front / Back Card Container
            VStack(alignment: .leading, spacing: 16) {
                // Adler Marker & Tag Header
                HStack {
                    if let marker = card.adlerTag {
                        HStack(spacing: 5) {
                            Text(marker.symbol)
                                .font(.system(size: 13, weight: .black))
                            Text(marker.title)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(marker.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(marker.accentColor.opacity(0.12), in: Capsule())
                    }
                    
                    Spacer()
                    
                    if isAnswerRevealed {
                        Text("ANSWER REVEALED")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.inkGreen)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.inkGreen.opacity(0.12), in: Capsule())
                    } else {
                        Text("TAP TO FLIP")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.inkTextTertiary)
                    }
                }
                
                Divider()
                    .background(Color.primary.opacity(0.08))
                
                // Card Body Content (Cloze / Markdown)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        if isAnswerRevealed {
                            revealedBodyView(card: card)
                        } else {
                            promptBodyView(card: card)
                        }
                    }
                }
                
                Spacer()
                
                // Citation Footer
                HStack(spacing: 6) {
                    Image(systemName: "book.pages.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.inkViolet)
                    
                    Text("\(card.citation.documentTitle) • p. \(card.citation.pageNumber)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.inkTextSecondary)
                        .lineLimit(1)
                    
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Color.inkSurface
                    .background(.ultraThinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        dragOffset.width < -40
                            ? Color.inkRed.opacity(0.6)
                            : dragOffset.width > 40
                                ? Color.inkGreen.opacity(0.6)
                                : Color.primary.opacity(0.1),
                        lineWidth: abs(dragOffset.width) > 40 ? 2 : 1
                    )
            )
            .shadow(color: Color.black.opacity(0.15), radius: 16, x: 0, y: 8)
            .offset(x: dragOffset.width, y: dragOffset.height * 0.4)
            .rotationEffect(.degrees(Double(dragOffset.width / 20.0)))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        if value.translation.width > swipeThreshold {
                            // Swipe Right -> Good
                            rateAndAdvance(rating: .good)
                        } else if value.translation.width < -swipeThreshold {
                            // Swipe Left -> Again
                            rateAndAdvance(rating: .again)
                        } else {
                            // Reset
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                dragOffset = .zero
                            }
                        }
                    }
            )
            .onTapGesture {
                HapticEngine.light()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isAnswerRevealed.toggle()
                }
            }
        }
    }
    
    // MARK: - Prompt & Revealed Subviews
    
    @ViewBuilder
    private func promptBodyView(card: StudyCard) -> some View {
        let masked = clozeParser.generateMaskedPrompt(from: card.markdownBody)
        Text(masked)
            .font(.system(size: 16, weight: .medium, design: .rounded))
            .foregroundColor(.inkTextPrimary)
            .lineSpacing(6)
    }
    
    @ViewBuilder
    private func revealedBodyView(card: StudyCard) -> some View {
        let segments = clozeParser.parseSegments(from: card.markdownBody)
        
        Text(segments.reduce(into: AttributedString()) { attr, segment in
            var part = AttributedString(segment.text)
            if segment.isCloze {
                part.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.2)
                part.foregroundColor = UIColor.systemGreen
                part.font = .systemFont(ofSize: 16, weight: .bold)
            } else {
                part.font = .systemFont(ofSize: 16, weight: .medium)
            }
            attr.append(part)
        })
        .lineSpacing(6)
    }
    
    // MARK: - Rating Action Bar
    
    private func ratingActionBar(card: StudyCard) -> some View {
        let intervals = scheduler.previewProjectedIntervals(for: card)
        
        return HStack(spacing: 10) {
            ForEach(StudyReviewRating.allCases) { rating in
                Button {
                    rateAndAdvance(rating: rating)
                } label: {
                    VStack(spacing: 3) {
                        Text(rating.rawValue)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text(intervals[rating] ?? "")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(rating.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: rating.color.opacity(0.3), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(rating.keyboardShortcutHint)), modifiers: [])
            }
        }
    }
    
    // MARK: - Rating Handler
    
    private func rateAndAdvance(rating: StudyReviewRating) {
        guard let card = currentCard else { return }
        
        HapticEngine.medium()
        if rating == .again {
            againCount += 1
        } else {
            goodCount += 1
        }
        reviewedCount += 1
        
        // Persist through store
        store.rateCard(withID: card.id, rating: rating)
        
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            dragOffset = .zero
            isAnswerRevealed = false
            if currentIndex + 1 < reviewCards.count {
                currentIndex += 1
            } else {
                isSessionComplete = true
                onSessionCompleted?(reviewedCount)
            }
        }
    }
    
    // MARK: - Session Complete View
    
    private var sessionCompleteView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 54))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.inkViolet, .inkBlue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            Text("Review Session Complete!")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.inkTextPrimary)
            
            Text("You reviewed \(reviewedCount) card\(reviewedCount == 1 ? "" : "s") with active recall.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(.inkTextSecondary)
            
            HStack(spacing: 24) {
                VStack {
                    Text("\(goodCount)")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.inkGreen)
                    Text("Mastered")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.inkTextTertiary)
                }
                
                VStack {
                    Text("\(againCount)")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.inkRed)
                    Text("Again")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.inkTextTertiary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(maxWidth: 200)
                    .padding(.vertical, 12)
                    .background(Color.inkViolet, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .padding(32)
    }
}

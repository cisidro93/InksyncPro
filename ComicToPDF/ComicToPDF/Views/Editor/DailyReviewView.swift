import SwiftUI
import SwiftData

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
    
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                
                if showComplete {
                    completionView
                } else if reviewQueue.isEmpty {
                    emptyStateView
                } else if currentIndex < reviewQueue.count {
                    reviewCard(for: reviewQueue[currentIndex])
                }
            }
            .navigationTitle("Daily Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear(perform: buildQueue)
        }
    }
    
    private func buildQueue() {
        let now = Date()
        let due = allHighlights.filter { $0.nextReviewDate == nil || $0.nextReviewDate! <= now }
        // Shuffle the due highlights and take up to 10 for a quick daily review
        reviewQueue = Array(due.shuffled().prefix(10))
    }
    
    @ViewBuilder
    private var completionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("You're all caught up!")
                .font(.title2.bold())
            Text("You have reviewed all due highlights for today.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(.top, 20)
        }
        .padding()
    }
    
    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No highlights due for review.")
                .font(.title2.bold())
            Text("As you read and highlight books, they will appear here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
    
    @ViewBuilder
    private func reviewCard(for annotation: SDAnnotation) -> some View {
        VStack {
            Spacer()
            
            VStack(alignment: .leading, spacing: 20) {
                if let bookTitle = annotation.readwiseBookTitle ?? annotation.chapterTitle {
                    Text(bookTitle)
                        .font(.caption.bold())
                        .foregroundStyle(Theme.accent)
                }
                
                Text(annotation.selectedText ?? "No text")
                    .font(.title3)
                    .lineSpacing(6)
                    .foregroundStyle(.primary)
                
                if !showFront {
                    Divider()
                    if let note = annotation.noteText {
                        Text("Note: \(note)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No note attached.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
            .padding(.horizontal, 20)
            
            Spacer()
            
            if showFront {
                Button {
                    withAnimation { showFront = false }
                } label: {
                    Text("Show Details")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Theme.surface)
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.05), radius: 5)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            } else {
                HStack(spacing: 15) {
                    reviewButton(title: "Hard", color: .red) { submitReview(annotation: annotation, quality: 1) }
                    reviewButton(title: "Good", color: .green) { submitReview(annotation: annotation, quality: 4) }
                    reviewButton(title: "Easy", color: .blue) { submitReview(annotation: annotation, quality: 5) }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
    }
    
    private func reviewButton(title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(color.opacity(0.15))
                .foregroundStyle(color)
                .cornerRadius(12)
        }
    }
    
    // Basic SM-2 Spaced Repetition Algorithm
    private func submitReview(annotation: SDAnnotation, quality: Int) {
        annotation.reviewCount += 1
        
        let newEase = annotation.easeFactor + (0.1 - Double(5 - quality) * (0.08 + Double(5 - quality) * 0.02))
        annotation.easeFactor = max(1.3, newEase)
        
        let interval: Double
        if annotation.reviewCount == 1 {
            interval = 1
        } else if annotation.reviewCount == 2 {
            interval = 6
        } else {
            interval = round(Double(annotation.reviewCount - 1) * annotation.easeFactor)
        }
        
        // Convert interval (days) to seconds
        annotation.nextReviewDate = Date().addingTimeInterval(interval * 24 * 60 * 60)
        
        try? modelContext.save()
        
        withAnimation {
            currentIndex += 1
            showFront = true
            if currentIndex >= reviewQueue.count {
                showComplete = true
            }
        }
    }
}

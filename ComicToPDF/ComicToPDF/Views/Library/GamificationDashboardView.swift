import SwiftUI
import Combine

enum StreakTheme: String, CaseIterable, Identifiable {
    case classic = "Classic Energy"
    case fantasy = "High Fantasy"
    case scifi = "Deep Sci-Fi"
    case manga = "Shonen Manga"
    case horror = "Horror / Noir"
    case textbook = "Academic"
    
    var id: String { self.rawValue }
    
    var icon: String {
        switch self {
        case .classic: return "bolt.fill"
        case .fantasy: return "wand.and.stars"
        case .scifi: return "circle.hexagonpath.fill"
        case .manga: return "burst.fill"
        case .horror: return "skull.fill"
        case .textbook: return "brain.head.profile"
        }
    }
    
    var color: Color {
        switch self {
        case .classic: return .yellow
        case .fantasy: return .purple
        case .scifi: return .cyan
        case .manga: return .pink
        case .horror: return .red
        case .textbook: return .blue
        }
    }
    
    var streakNoun: String {
        switch self {
        case .classic: return "Reading Streak"
        case .fantasy: return "Active Quest"
        case .scifi: return "Lightyears Traveled"
        case .manga: return "Power Level"
        case .horror: return "Survival Days"
        case .textbook: return "Scholarship"
        }
    }
    
    var chargeNoun: String {
        switch self {
        case .classic: return "Streak Charges"
        case .fantasy: return "Mana Flasks"
        case .scifi: return "Shield Cells"
        case .manga: return "Aura Sparks"
        case .horror: return "Soul Fragments"
        case .textbook: return "Focus Tokens"
        }
    }
    
    var gradient: LinearGradient {
        switch self {
        case .classic: return LinearGradient(colors: [.yellow, .orange], startPoint: .leading, endPoint: .trailing)
        case .fantasy: return LinearGradient(colors: [.purple, .indigo, .pink], startPoint: .leading, endPoint: .trailing)
        case .scifi: return LinearGradient(colors: [.cyan, .green], startPoint: .leading, endPoint: .trailing)
        case .manga: return LinearGradient(colors: [.pink, .red], startPoint: .leading, endPoint: .trailing)
        case .horror: return LinearGradient(colors: [Color(red: 0.6, green: 0, blue: 0), .black], startPoint: .leading, endPoint: .trailing)
        case .textbook: return LinearGradient(colors: [.blue, .indigo], startPoint: .leading, endPoint: .trailing)
        }
    }
    
    var glowColor: Color {
        switch self {
        case .classic: return Color.yellow.opacity(0.15)
        case .fantasy: return Color.purple.opacity(0.15)
        case .scifi: return Color.cyan.opacity(0.15)
        case .manga: return Color.pink.opacity(0.15)
        case .horror: return Color.red.opacity(0.15)
        case .textbook: return Color.blue.opacity(0.15)
        }
    }
}

struct GamificationDashboardView: View {
    @ObservedObject var gamification = GamificationManager.shared
    @AppStorage("streakTheme") private var streakTheme: StreakTheme = .classic
    @State private var serendipityHighlights: [Annotation] = []
    
    var body: some View {
        VStack(spacing: 16) {
            // Streak & Charges Card
            HStack(spacing: 20) {
                VStack(alignment: .leading) {
                    Text(streakTheme.streakNoun)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(gamification.currentStreak)")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text(gamification.currentStreak == 1 ? "day" : "days")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text(streakTheme.chargeNoun)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: streakTheme.icon)
                            .foregroundColor(streakTheme.color)
                            .shadow(color: streakTheme.glowColor, radius: 4)
                        Text("\(gamification.streakCharges)")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                    }
                }
            }
            .padding()
            .background(Color.inkSurface)
            .cornerRadius(12)
            .shadow(color: streakTheme.glowColor, radius: 10)
            
            // Daily Goal Progress
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Daily Goal")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(gamification.pagesReadToday) / \(gamification.dailyPageGoal)")
                        .font(.caption)
                        .bold()
                }
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.inkSurfaceRaised)
                            .frame(height: 8)
                        
                        let progress = min(1.0, Double(gamification.pagesReadToday) / Double(max(1, gamification.dailyPageGoal)))
                        Capsule()
                            .fill(streakTheme.gradient)
                            .frame(width: max(0, geo.size.width * CGFloat(progress)), height: 8)
                            .shadow(color: streakTheme.glowColor, radius: 4)
                    }
                }
                .frame(height: 8)
            }
            .padding()
            .background(Color.inkSurface)
            .cornerRadius(12)
            .shadow(color: streakTheme.glowColor, radius: 10)
            
            // Serendipity Engine
            if gamification.enableSerendipity {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundColor(streakTheme.color)
                        Text("Daily Serendipity")
                            .font(.headline)
                        Spacer()
                    }
                    
                    if serendipityHighlights.isEmpty {
                        Text("Read and highlight more books to unlock daily Serendipity insights!")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(serendipityHighlights) { highlight in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(highlight.chapterTitle ?? "Unknown Chapter")
                                    .font(.caption)
                                    .foregroundColor(streakTheme.color)
                                Text(highlight.selectedText ?? highlight.noteText ?? "")
                                    .font(.subheadline)
                                    .italic()
                                    .foregroundColor(.primary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.inkSurfaceRaised)
                            .cornerRadius(8)
                        }
                    }
                }
                .padding()
                .background(Color.inkSurface)
                .cornerRadius(12)
                .shadow(color: streakTheme.glowColor, radius: 10)
                .onAppear { loadSerendipity() }
            }
        }
        .padding(.horizontal)
    }
    
    private func loadSerendipity() {
        let annotations: [Annotation] = AnnotationStore.shared.allAnnotations
        let allHighlights = annotations.filter { annotation -> Bool in
            let isHighlight = (annotation.kind == .highlight)
            let isNote = (annotation.kind == .note)
            return isHighlight || isNote
        }
        guard !allHighlights.isEmpty else { return }
        self.serendipityHighlights = Array(allHighlights.shuffled().prefix(5))
    }
}

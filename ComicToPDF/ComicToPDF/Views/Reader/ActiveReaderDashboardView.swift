import SwiftUI

struct ActiveReaderDashboardView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject var tracker = ReaderProgressTracker.shared
    
    @State private var pdfToRead: ConvertedPDF?
    
    // Derived state
    var recentPDFs: [(progress: ReadingProgress, pdf: ConvertedPDF)] {
        let sessions = tracker.recentSessions()
        return sessions.compactMap { session in
            if let pdf = conversionManager.convertedPDFs.first(where: { $0.id == session.pdfID }) {
                return (session, pdf)
            }
            return nil
        }
    }
    
    var activeHero: (progress: ReadingProgress, pdf: ConvertedPDF)? {
        recentPDFs.first(where: { $0.progress.completionFraction < 0.98 })
    }
    
    var shelfItems: [(progress: ReadingProgress, pdf: ConvertedPDF)] {
        let heroID = activeHero?.pdf.id
        return recentPDFs.filter { $0.pdf.id != heroID }.prefix(10).map { $0 }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // ── GAMIFICATION DASHBOARD ───────────────────
                GamificationDashboardView()
                    .padding(.top, 20)
                
                if let hero = activeHero {
                    // ── HERO SECTION ─────────────────────────
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Continue Reading")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                        
                        Button {
                            pdfToRead = hero.pdf
                        } label: {
                            heroCard(for: hero)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    // ── RECENT SHELF ─────────────────────────
                    if !shelfItems.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Jump Back In")
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 20)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    ForEach(shelfItems, id: \.pdf.id) { item in
                                        Button {
                                            pdfToRead = item.pdf
                                        } label: {
                                            shelfCard(for: item)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.bottom, 20)
                            }
                        }
                    }
                } else {
                    // ── EMPTY STATE ──────────────────────────
                    emptyStateView
                }
            }
        }
        .background(Color.inkBackground.ignoresSafeArea())
        .navigationTitle("Reading")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $pdfToRead) { pdf in
             if pdf.contentType == .book {
                 SplitStudyWorkspace(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf)
             } else {
                 ReaderView(fileURL: pdf.url, contentType: pdf.contentType, pdf: pdf)
             }
        }
    }
    
    // MARK: - Components
    
    @ViewBuilder
    private func heroCard(for item: (progress: ReadingProgress, pdf: ConvertedPDF)) -> some View {
        let pdf = item.pdf
        let progress = item.progress
        
        HStack(spacing: 20) {
            // Cover
            ZStack {
                Color.secondary.opacity(0.1)
                ComicCoverLoader(pdf: pdf)
                    .scaledToFill()
            }
            .frame(width: 120, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color.black.opacity(0.15), radius: 8, y: 4)
            
            // Metadata
            VStack(alignment: .leading, spacing: 6) {
                if let series = pdf.metadata.series {
                    Text(series.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.orange)
                        .tracking(1.0)
                }
                
                Text(pdf.name)
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(2)
                    .foregroundColor(.primary)
                
                Text(pdf.contentType == .book ? "E-Book" : "Comic")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 6)
                
                // Progress Bar
                VStack(alignment: .leading, spacing: 4) {
                    let pct = max(0.0, min(1.0, progress.completionFraction))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1)).frame(height: 6)
                            Capsule().fill(
                                LinearGradient(colors: [Theme.orange, Theme.red], startPoint: .leading, endPoint: .trailing)
                            )
                            .frame(width: max(0, geo.size.width * CGFloat(pct)), height: 6)
                        }
                    }
                    .frame(height: 6)
                    
                    HStack {
                        Text("\(Int(pct * 100))% Complete")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        if let est = progress.estimatedMinutesRemaining, est > 0 {
                            Text("\(est)m left")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
            }
            .padding(.vertical, 10)
        }
        .padding(16)
        .background(Color.inkSurface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 10, y: 5)
        .padding(.horizontal, 20)
    }
    
    @ViewBuilder
    private func shelfCard(for item: (progress: ReadingProgress, pdf: ConvertedPDF)) -> some View {
        let pdf = item.pdf
        let progress = item.progress
        
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.secondary.opacity(0.1)
                ComicCoverLoader(pdf: pdf)
                    .scaledToFill()
            }
            .frame(width: 90, height: 135)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: Color.black.opacity(0.1), radius: 4, y: 2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(pdf.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(.primary)
                
                let pct = progress.completionFraction
                Text("\(Int(pct * 100))% Read")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .frame(width: 90, alignment: .leading)
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 60)
            
            ZStack {
                Circle()
                    .fill(Theme.orange.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "book.pages")
                    .font(.system(size: 40))
                    .foregroundColor(Theme.orange)
            }
            
            VStack(spacing: 8) {
                Text("Your Shelf is Empty")
                    .font(.title2.bold())
                Text("Once you start reading comics or books from your Library, they'll appear here for quick access.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            Spacer()
        }
    }
}

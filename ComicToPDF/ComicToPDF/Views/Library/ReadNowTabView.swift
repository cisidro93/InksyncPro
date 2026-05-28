import SwiftUI

struct ReadNowTabView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject private var tracker = ReaderProgressTracker.shared
    @StateObject private var velocityVM = VelocityViewModel()

    @State private var pdfToRead: ConvertedPDF?

    var continueReadingItems: [ConvertedPDF] {
        conversionManager.convertedPDFs.filter { pdf in
            guard let prog = tracker.progress(for: pdf.id) else { return false }
            return prog.completionFraction > 0.0 && prog.completionFraction < 0.98
        }.sorted {
            let a = tracker.progress(for: $0.id)?.lastOpenedAt ?? .distantPast
            let b = tracker.progress(for: $1.id)?.lastOpenedAt ?? .distantPast
            return a > b
        }.prefix(8).map { $0 }
    }

    var recentlyAddedItems: [ConvertedPDF] {
        Array(conversionManager.convertedPDFs.suffix(8).reversed())
    }

    // Stats for the summary row (StoryGraph / Goodreads influence)
    private var completedCount: Int {
        conversionManager.convertedPDFs.filter {
            (tracker.progress(for: $0.id)?.completionFraction ?? 0) >= 0.98
        }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 28) {

                        // ── Stats strip (StoryGraph style) ─────────────────────────
                        HStack(spacing: 0) {
                            statPill(value: "\(conversionManager.convertedPDFs.count)",
                                     label: "In Library",
                                     icon: "books.vertical.fill",
                                     color: Theme.orange)
                            divider
                            statPill(value: "\(continueReadingItems.count)",
                                     label: "In Progress",
                                     icon: "book.fill",
                                     color: Theme.blue)
                            divider
                            statPill(value: "\(completedCount)",
                                     label: "Finished",
                                     icon: "checkmark.seal.fill",
                                     color: Theme.green)
                        }
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        // ── Continue Reading shelf ──────────────────────────────────
                        if !continueReadingItems.isEmpty {
                            shelfSection(
                                title: "Continue Reading",
                                icon: "book.fill",
                                iconColor: Theme.orange,
                                count: continueReadingItems.count
                            ) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 14) {
                                        ForEach(continueReadingItems) { pdf in
                                            Button {
                                                pdfToRead = pdf
                                            } label: {
                                                ReadNowCard(
                                                    pdf: pdf,
                                                    forecast: velocityVM.forecast(for: pdf.id)
                                                )
                                            }
                                            .buttonStyle(CellButtonStyle())
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }

                                // ── Velocity stats footer ──────────────────────
                                if let report = velocityVM.report, report.global.pagesPerDay > 0 {
                                    HStack(spacing: 20) {
                                        velocityPill(
                                            icon: "gauge.medium",
                                            value: String(format: "%.0f", report.global.pagesPerDay),
                                            label: "pages/day",
                                            color: Theme.blue
                                        )
                                        if let days = report.global.projectedLibraryFinishDays, days > 0 {
                                            velocityPill(
                                                icon: "calendar.badge.clock",
                                                value: days < 365 ? "\(days)d" : "\(days/365)y",
                                                label: "to clear queue",
                                                color: Theme.orange
                                            )
                                        }
                                        velocityPill(
                                            icon: "bolt.fill",
                                            value: String(format: "%.0f", report.global.pagesPerSession),
                                            label: "pages/session",
                                            color: .purple
                                        )
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.top, 4)
                                }
                            }
                        }

                        // ── Recently Added shelf ────────────────────────────────────
                        if !recentlyAddedItems.isEmpty {
                            shelfSection(
                                title: "Recently Added",
                                icon: "plus.circle.fill",
                                iconColor: Theme.blue,
                                count: nil
                            ) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 14) {
                                        ForEach(recentlyAddedItems) { pdf in
                                            Button {
                                                pdfToRead = pdf
                                            } label: {
                                                CompactReadNowCard(pdf: pdf)
                                            }
                                            .buttonStyle(CellButtonStyle())
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationTitle("Read Now")
            .navigationBarTitleDisplayMode(.large)
            .fullScreenCover(item: $pdfToRead) { pdf in
                UnifiedReaderView(pdf: pdf)
            }
            .onAppear {
                velocityVM.refresh(pdfs: conversionManager.convertedPDFs, tracker: tracker)
            }
            .onChange(of: conversionManager.convertedPDFs.count) { _, _ in
                velocityVM.refresh(pdfs: conversionManager.convertedPDFs, tracker: tracker)
            }
        }
    }

    // MARK: - Section Header Builder (Panels-style)
    @ViewBuilder
    private func shelfSection<Content: View>(
        title: String,
        icon: String,
        iconColor: Color,
        count: Int?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(iconColor)
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundColor(Theme.text)
                    .tracking(1.2)
                if let count {
                    Text("· \(count)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                // "See All" chevron (Panels pattern)
                HStack(spacing: 3) {
                    Text("See All")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 16)

            content()
        }
    }

    // MARK: - Stats Helpers
    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 36)
    }

    private func statPill(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(color)
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.text)
            }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Velocity Pill Helper
    private func velocityPill(icon: String, value: String, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.text)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Large Continue Reading Card (Panels / Netflix style)
struct ReadNowCard: View {
    let pdf: ConvertedPDF
    var forecast: VelocityReport.BookForecast? = nil
    @EnvironmentObject var conversionManager: ConversionManager
    @ObservedObject private var tracker = ReaderProgressTracker.shared

    private var progress: Double {
        tracker.progress(for: pdf.id)?.completionFraction ?? 0
    }
    private var pageInfo: String {
        if let prog = tracker.progress(for: pdf.id) {
            let current = prog.currentPageIndex + 1
            return "p. \(current) · \(Int(progress * 100))% done"
        }
        return ""
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Cover
            Group {
                if let img = conversionManager.getThumbnail(for: pdf) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.15, green: 0.25, blue: 0.6), Color(red: 0.1, green: 0.15, blue: 0.4)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: "book.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            .frame(width: 180, height: 260)

            // Bottom scrim
            LinearGradient(
                colors: [.clear, .black.opacity(0.85)],
                startPoint: .center,
                endPoint: .bottom
            )

            // Overlaid title + progress (Kindle / Panels style)
            VStack(alignment: .leading, spacing: 6) {
                Text(pdf.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.5), radius: 3)

                Text(pageInfo)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.75))

                // Progress bar on card bottom edge
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2)).frame(height: 3)
                        Capsule().fill(Color.white).frame(width: g.size.width * CGFloat(progress), height: 3)
                    }
                }
                .frame(height: 3)
            }
            .padding(12)
        }
        .frame(width: 180, height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            // ── "Finish By" velocity badge ─────────────────────
            if let forecast, forecast.finishDate != nil {
                HStack(spacing: 3) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 9, weight: .bold))
                    Text(forecast.finishByShortLabel)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(forecast.isAheadOfPace
                            ? Color.green.opacity(0.85)
                            : Color.orange.opacity(0.85))
                )
                .padding(8)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 4, y: 3)
        .shadow(color: .black.opacity(0.10), radius: 14, y: 10)
    }
}

// MARK: - Compact Recently Added Card
struct CompactReadNowCard: View {
    let pdf: ConvertedPDF
    @EnvironmentObject var conversionManager: ConversionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let img = conversionManager.getThumbnail(for: pdf) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.2, green: 0.2, blue: 0.35), Color(red: 0.12, green: 0.12, blue: 0.25)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.35))
                }
            }
            .frame(width: 120, height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
            .shadow(color: .black.opacity(0.08), radius: 10, y: 6)

            Text(pdf.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.text)
                .lineLimit(2)
                .frame(width: 120, alignment: .leading)
        }
    }
}

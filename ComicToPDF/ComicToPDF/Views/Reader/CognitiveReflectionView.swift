import SwiftUI
import SwiftData

struct CognitiveReflectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    @Query(sort: \SDAnnotation.modifiedAt, order: .reverse) private var allAnnotations: [SDAnnotation]
    @Query private var allPDFs: [SDConvertedPDF]
    
    // Computed reflection metrics
    private var totalHighlightsCount: Int {
        allAnnotations.filter { $0.kindRaw == "highlight" }.count
    }
    
    private var totalNotesCount: Int {
        allAnnotations.filter { $0.kindRaw == "note" }.count
    }
    
    private var totalConnectionsCount: Int {
        allAnnotations.reduce(0) { total, ann in
            total + (ann.linkedAnnotationIDs?.count ?? 0)
        }
    }
    
    private var tagCounts: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for ann in allAnnotations {
            let tags = (ann.tags ?? []) + (ann.readwiseTags ?? []) + (ann.readwiseDocumentTags ?? [])
            for tag in tags {
                let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !clean.isEmpty {
                    counts[clean, default: 0] += 1
                }
            }
        }
        return counts.sorted { $0.value > $1.value }
    }
    
    private var colorDistribution: [(color: Color, name: String, percentage: Double)] {
        let highlights = allAnnotations.filter { $0.kindRaw == "highlight" }
        guard !highlights.isEmpty else { return [] }
        
        let colorMap: [String: (Color, String)] = [
            "#FFD60A": (Color(hex: "#FFD60A"), "Yellow"),
            "#007AFF": (Color(hex: "#007AFF"), "Blue"),
            "#FF2D55": (Color(hex: "#FF2D55"), "Pink"),
            "#32ADE6": (Color(hex: "#32ADE6"), "Aqua"),
            "#FF9F0A": (Color(hex: "#FF9F0A"), "Orange"),
            "#BF5AF2": (Color(hex: "#BF5AF2"), "Purple")
        ]
        
        var counts: [String: Int] = [:]
        for h in highlights {
            let hex = h.colorHex?.uppercased() ?? "#FFD60A"
            counts[hex, default: 0] += 1
        }
        
        let total = Double(highlights.count)
        return counts.compactMap { hex, count in
            guard let mapped = colorMap[hex] else { return nil }
            return (color: mapped.0, name: mapped.1, percentage: Double(count) / total)
        }.sorted { $0.percentage > $1.percentage }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color.inkBackground.ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        
                        // Header info
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Cognitive Reflection")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.inkTextPrimary)
                            Text("An un-gamified mirror of your reading journey and conceptual connections.")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.inkTextSecondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        
                        // 1. Knowledge Density stats grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            statCard(title: "Highlights", count: totalHighlightsCount, icon: "highlighter", color: Color.inkAccentKnowledge)
                            statCard(title: "Written Notes", count: totalNotesCount, icon: "note.text", color: Color(hex: "#30D5C8"))
                            statCard(title: "Zettel Links", count: totalConnectionsCount, icon: "point.3.connected.trianglepath.dotted", color: Color(hex: "#BF5AF2"))
                            statCard(title: "Book Sources", count: allPDFs.count, icon: "book.closed.fill", color: Color(hex: "#FF9F0A"))
                        }
                        .padding(.horizontal, 20)
                        
                        // 2. Tag Concept Cloud
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Top Concepts & Tags")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.inkTextPrimary)
                            
                            if tagCounts.isEmpty {
                                Text("No tags assigned yet. Tag your highlights to build a concept cloud.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.inkTextTertiary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 20)
                            } else {
                                tagCloudView
                            }
                        }
                        .padding(.all, 20)
                        .background(Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                        .padding(.horizontal, 20)
                        
                        // 3. Highlight Color Coding distribution
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Theme Coding split")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.inkTextPrimary)
                            
                            if colorDistribution.isEmpty {
                                Text("No highlights made yet.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.inkTextTertiary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 20)
                            } else {
                                colorBreakdownList
                            }
                        }
                        .padding(.all, 20)
                        .background(Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                        .padding(.horizontal, 20)
                        
                        Spacer().frame(height: 40)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.inkAccentKnowledge)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private func statCard(title: String, count: Int, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.inkTextPrimary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color.inkTextSecondary)
            }
        }
        .padding(.all, 16)
        .background(Color.inkSurfaceRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.inkBorderSubtle, lineWidth: 0.5))
    }
    
    private var tagCloudView: some View {
        // Grid flow showing top tags
        VStack(alignment: .leading, spacing: 10) {
            Text("These represent the central pillars of your active research:")
                .font(.caption)
                .foregroundStyle(Color.inkTextSecondary)
                .padding(.bottom, 6)
            
            // Render top 12 tags
            let topTags = Array(tagCounts.prefix(12))
            
            // Simple flow-like grid layout
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 180))], spacing: 10) {
                ForEach(topTags, id: \.tag) { item in
                    HStack(spacing: 6) {
                        Text("#\(item.tag)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.inkTextPrimary)
                        
                        Text("\(item.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.inkAccentKnowledge.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.inkAccentKnowledge)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.inkBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.inkBorderSubtle, lineWidth: 0.5))
                }
            }
        }
    }
    
    private var colorBreakdownList: some View {
        VStack(spacing: 12) {
            // Horizontal stacked progress segment representing proportions
            HStack(spacing: 2) {
                ForEach(colorDistribution, id: \.name) { item in
                    Rectangle()
                        .fill(item.color)
                        .frame(height: 8)
                }
            }
            .cornerRadius(4)
            .padding(.bottom, 6)
            
            ForEach(colorDistribution, id: \.name) { item in
                HStack {
                    Circle()
                        .fill(item.color)
                        .frame(width: 8, height: 8)
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.inkTextPrimary)
                    Spacer()
                    Text(String(format: "%.0f%%", item.percentage * 100))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.inkTextSecondary)
                }
            }
        }
    }
}

fileprivate extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

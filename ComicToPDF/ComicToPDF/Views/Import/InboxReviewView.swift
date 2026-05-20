import SwiftUI

struct InboxReviewView: View {
    @EnvironmentObject var manager: ConversionManager
    
    // Derived subset of Library: Items lacking series or author (meaning they likely need review)
    var reviewItems: [ConvertedPDF] {
        manager.convertedPDFs.filter { (pdf: ConvertedPDF) -> Bool in
            let seriesEmpty = pdf.metadata.series?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            let authorEmpty = pdf.metadata.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            let titleEmpty = pdf.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return seriesEmpty || authorEmpty || titleEmpty
        }.sorted { $0.lastModified > $1.lastModified }
    }
    
    var body: some View {
        ZStack {
            Color.inkBackground.ignoresSafeArea()
            
            if reviewItems.isEmpty {
                VStack(spacing: 0) {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    gradient: Gradient(colors: [Theme.green.opacity(0.35), Theme.blue.opacity(0.15), .clear]),
                                    center: .center,
                                    startRadius: 20,
                                    endRadius: 72
                                )
                            )
                            .frame(width: 144, height: 144)
                            .blur(radius: 24)

                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .frame(width: 96, height: 96)
                            .overlay(
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .stroke(
                                        LinearGradient(
                                            colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1
                                    )
                            )
                            .shadow(color: Theme.green.opacity(0.2), radius: 20, y: 8)

                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Theme.green, Theme.blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .padding(.bottom, 32)
                    
                    Text("Inbox is Clear")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(Theme.text)
                        .padding(.bottom, 8)
                        
                    Text("All comics in your library have complete metadata.")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.horizontal, 40)
                        
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Metadata Review")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(Theme.text)
                            Text("\(reviewItems.count) items need metadata matching.")
                                .font(.system(size: 14))
                                .foregroundColor(Theme.textSecondary)
                        }
                        Spacer()
                        
                        ActionPill(title: "Auto-Match", icon: "wand.and.stars.inverse", color: Theme.orange) {
                            Task {
                                await BackgroundMetadataEngine.shared.startEngine(manager: manager)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    
                    List {
                        ForEach(reviewItems) { item in
                            HStack(spacing: 12) {
                                if let coverURL = manager.getCoverURL(for: item),
                                   let uiImage = UIImage(contentsOfFile: coverURL.path) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 44, height: 66)
                                        .cornerRadius(8)
                                        .clipped()
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Theme.surfaceElevated)
                                        .frame(width: 44, height: 66)
                                        .overlay(Image(systemName: "photo").foregroundColor(Theme.textTertiary))
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.metadata.title.isEmpty ? item.name : item.metadata.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(Theme.text)
                                        .lineLimit(1)
                                    
                                    HStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .font(.system(size: 10))
                                        Text("Missing: \(missingTags(for: item))")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundColor(Theme.orange)
                                }
                                
                                Spacer()
                                
                                NavigationLink(destination: AdvancedMetadataEditorView(pdf: item)) {
                                    Text("Edit")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(Theme.orange)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                        .background(Theme.orange.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 14)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.inkBorderSubtle, lineWidth: 1))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable {
                        // Force re-evaluate which items are missing metadata
                        await BackgroundMetadataEngine.shared.startEngine(manager: manager)
                    }
                }
            }
        }
    }
    
    private func missingTags(for item: ConvertedPDF) -> String {
        var missing: [String] = []
        if (item.metadata.series?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) { missing.append("Series") }
        if (item.metadata.author?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) { missing.append("Creator") }
        if item.metadata.title.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("Title") }
        return missing.joined(separator: ", ")
    }
}

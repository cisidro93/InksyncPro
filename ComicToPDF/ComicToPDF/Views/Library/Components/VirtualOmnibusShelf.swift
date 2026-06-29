import SwiftUI

struct VirtualOmnibusShelf: View {
    @EnvironmentObject var conversionManager: ConversionManager
    let omnibuses: [VirtualOmnibus]
    let onEdit: (VirtualOmnibus) -> Void
    let onRead: (VirtualOmnibus) -> Void
    
    @Environment(\.horizontalSizeClass) private var hSizeClass
    
    var body: some View {
        if !omnibuses.isEmpty {
            VStack(spacing: 12) {
                // Shelf Header
                HStack {
                    Text("Virtual Volumes & Omnibuses")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(.uppercase)
                        .tracking(1.2)
                    Spacer()
                }
                .padding(.horizontal, hSizeClass == .regular ? 24 : 16)
                
                // Horizontal Carousel Scroll
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(omnibuses) { omnibus in
                            VirtualOmnibusCard(omnibus: omnibus, onEdit: { onEdit(omnibus) })
                                .onTapGesture { onRead(omnibus) }
                        }
                    }
                    .padding(.horizontal, hSizeClass == .regular ? 24 : 16)
                    .padding(.vertical, 8)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }
}

private struct VirtualOmnibusCard: View {
    let omnibus: VirtualOmnibus
    let onEdit: () -> Void
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var coverImage: UIImage? = nil
    
    var firstPDF: ConvertedPDF? {
        guard let firstId = omnibus.fileIDs.first else { return nil }
        return conversionManager.convertedPDFs.first(where: { $0.id == firstId })
    }
    
    var totalIssuesCount: Int {
        omnibus.fileIDs.count
    }
    
    var progress: Double {
        let resolvedFiles = omnibus.fileIDs.compactMap { id in
            conversionManager.convertedPDFs.first(where: { $0.id == id })
        }
        let totalPages = resolvedFiles.reduce(0) { $0 + max($1.pageCount, 1) }
        let readPages = resolvedFiles.reduce(0) { $0 + ($1.metadata.lastReadPage ?? 0) }
        guard totalPages > 0 else { return 0 }
        return Double(readPages) / Double(totalPages)
    }
    
    var formattedProgress: String {
        String(format: "%.0f%% read", progress * 100)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                // Cover Art
                Group {
                    if let uiImage = coverImage {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                    } else if let first = firstPDF, let data = first.coverImageData, let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.inkSurfaceRaised)
                            .overlay(
                                Image(systemName: "books.vertical.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(.inkTextTertiary)
                            )
                    }
                }
                .frame(width: 140, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5)
                )
                
                // Virtual Tag Badge
                Text("VIRTUAL")
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.inkAccentKnowledge, in: Capsule())
                    .padding(8)
            }
            
            // Metadata info
            VStack(alignment: .leading, spacing: 3) {
                Text(omnibus.name)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.inkTextPrimary)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
                
                HStack {
                    Text("\(totalIssuesCount) issues")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.inkTextSecondary)
                    Spacer()
                    
                    // Edit button
                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundColor(.inkBlue)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 140)
                
                // Progress Bar
                if progress > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.inkBorderSubtle)
                                .frame(height: 3)
                            Capsule()
                                .fill(progress >= 0.98 ? Color.inkGreen : Color.inkBlue)
                                .frame(width: geo.size.width * CGFloat(progress), height: 3)
                        }
                    }
                    .frame(height: 3)
                    .frame(width: 140)
                    .padding(.top, 2)
                }
            }
        }
        .task(id: omnibus.id) {
            await loadCover()
        }
        .onReceive(conversionManager.thumbnailReadySubject.receive(on: RunLoop.main)) { updatedID in
            let coverID = omnibus.coverFileID ?? omnibus.fileIDs.first
            if updatedID == coverID {
                Task {
                    await loadCover()
                }
            }
        }
        .contextMenu {
            if omnibus.remoteSyncURL != nil && !omnibus.remoteSyncURL!.isEmpty {
                Button {
                    Task {
                        await LibraryService.shared.syncRemoteVirtualOmnibus(omnibus)
                    }
                } label: {
                    Label("Sync from Remote", systemImage: "arrow.clockwise.icloud")
                }
            }
            
            Button {
                onEdit()
            } label: {
                Label("Edit Virtual Volume", systemImage: "pencil")
            }
            
            Button(role: .destructive) {
                deleteOmnibus()
            } label: {
                Label("Delete Volume", systemImage: "trash")
            }
        }
    }
    
    private func loadCover() async {
        let coverPDF: ConvertedPDF? = {
            if let coverID = omnibus.coverFileID {
                return conversionManager.convertedPDFs.first(where: { $0.id == coverID })
            }
            return firstPDF
        }()
        
        guard let pdf = coverPDF else { return }
        let key = pdf.id.uuidString as NSString
        
        if let cached = conversionManager.thumbnailCache.object(forKey: key) {
            self.coverImage = cached
            return
        }
        
        await conversionManager.loadThumbnailAsync(for: pdf)
        if let loaded = conversionManager.thumbnailCache.object(forKey: key) {
            self.coverImage = loaded
        }
    }
    
    private func deleteOmnibus() {
        withAnimation {
            conversionManager.virtualOmnibuses.removeAll(where: { $0.id == omnibus.id })
        }
    }
}

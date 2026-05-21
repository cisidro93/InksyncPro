import SwiftUI

// MARK: - OPDS Book Grid

/// Displays acquisition entries (actual books) from an OPDS feed.
/// Primary action routes to the correct reader:
///   • Divina / WebPub (entry.divinaPageURLs != nil) → OPDSDivinaReader
///   • PSE stream (entry.streamURL != nil)           → OPDSPSEReader
///   • Download-only (Calibre)                       → progressive download
struct OPDSBookGrid: View {
    let server: SDOPDSServer
    let entries: [OPDSEntry]

    @State private var downloadProgress: [String: Double] = [:]
    @State private var downloadedFiles: [String: URL] = [:]
    @State private var activeErrors: [String: String] = [:]
    @State private var streamingEntry: OPDSEntry?

    @EnvironmentObject private var conversionManager: ConversionManager  // Item 5: smart routing
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var columns: [GridItem] {
        let count = hSizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(entries) { entry in
                OPDSBookCard(
                    entry: entry,
                    server: server,
                    downloadProgress: downloadProgress[entry.id],
                    isDownloaded: downloadedFiles[entry.id] != nil,
                    errorMessage: activeErrors[entry.id],
                    onStream: { streamEntry(entry) },
                    onDownload: { Task { await download(entry) } }
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .fullScreenCover(item: $streamingEntry) { entry in
            // Phase 3: route to Divina reader for OPDS 2.0 entries with readingOrder
            if entry.divinaPageURLs != nil {
                OPDSDivinaReader(server: server, entry: entry)
            } else {
                OPDSPSEReader(server: server, entry: entry)
            }
        }
    }

    // MARK: - Actions

    private func streamEntry(_ entry: OPDSEntry) {
        // Divina (OPDS 2.0 readingOrder) or PSE stream available
        if entry.divinaPageURLs != nil || entry.streamURL != nil ||
           server.serverType == .kavita || server.serverType == .komga {
            streamingEntry = entry
        } else {
            // Calibre: no stream protocol — progressive download then read
            Task { await download(entry, thenRead: true) }
        }
        Logger.shared.log("OPDSBookGrid: streaming '\(entry.title)'", category: "OPDS")
    }

    private func download(_ entry: OPDSEntry, thenRead: Bool = false) async {
        guard downloadProgress[entry.id] == nil else { return }  // already in progress

        withAnimation { downloadProgress[entry.id] = 0.01 }
        activeErrors.removeValue(forKey: entry.id)

        do {
            let fileURL = try await OPDSClient.shared.downloadEntry(entry, server: server) { progress in
                Task { @MainActor in
                    withAnimation { downloadProgress[entry.id] = progress }
                }
            }
            withAnimation {
                downloadProgress.removeValue(forKey: entry.id)
                downloadedFiles[entry.id] = fileURL
            }
            Logger.shared.log("OPDSBookGrid: downloaded '\(entry.title)' → \(fileURL.lastPathComponent)", category: "OPDS")

            // Import into library
            await conversionManager.processImportedFiles(urls: [fileURL])

            if thenRead {
                // Item 5: prefer the full ReaderView if the book is now in the library
                let baseName = fileURL.deletingPathExtension().lastPathComponent
                if let matched = conversionManager.convertedPDFs.first(where: {
                    $0.name == baseName || $0.fileURL?.lastPathComponent == fileURL.lastPathComponent
                }) {
                    await MainActor.run {
                        AppRouter.shared.presentFullScreen(.read(matched))
                    }
                } else {
                    // Fallback: open in PSE reader (stream path)
                    streamingEntry = entry
                }
            }
        } catch {
            withAnimation {
                downloadProgress.removeValue(forKey: entry.id)
                activeErrors[entry.id] = error.localizedDescription
            }
            Logger.shared.log("OPDSBookGrid: download failed '\(entry.title)' — \(error)", category: "OPDS", type: .error)
        }
    }
}

// MARK: - Book Card

struct OPDSBookCard: View {
    let entry: OPDSEntry
    let server: SDOPDSServer
    let downloadProgress: Double?
    let isDownloaded: Bool
    let errorMessage: String?
    let onStream: () -> Void
    let onDownload: () -> Void

    @State private var coverPhase: AsyncImagePhase = .empty

    private var canStream: Bool {
        entry.divinaPageURLs != nil || entry.streamURL != nil ||
        server.serverType == .kavita || server.serverType == .komga
    }

    private var streamBadgeLabel: String {
        entry.divinaPageURLs != nil ? "DIVINA" : "STREAM"
    }

    private var streamBadgeIcon: String {
        entry.divinaPageURLs != nil ? "books.vertical.fill" : "play.fill"
    }

    var body: some View {
        Button(action: onStream) {
            VStack(alignment: .leading, spacing: 8) {

                // Cover image
                coverStack

                // Metadata
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.inkTextPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if !entry.author.isEmpty {
                        Text(entry.author)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.inkTextSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .background(Color.inkSurface.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.inkTextPrimary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.inkTextPrimary.opacity(0.06), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .contextMenu {
            if canStream {
                Button {
                    onStream()
                } label: {
                    Label("Stream", systemImage: "play.circle.fill")
                }
            }

            Button {
                onDownload()
            } label: {
                Label(isDownloaded ? "Downloaded ✓" : "Download", systemImage: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
            }
            .disabled(isDownloaded || downloadProgress != nil)
        }
    }

    // MARK: - Cover Stack

    private var coverStack: some View {
        ZStack(alignment: .bottomTrailing) {
            // Cover image
            AsyncImage(url: entry.coverURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure, .empty:
                    placeholderCover
                @unknown default:
                    placeholderCover
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Download progress ring
            if let progress = downloadProgress {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 36, height: 36)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(server.serverType.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 26, height: 26)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: progress)
                }
                .padding(6)
                .transition(.scale.combined(with: .opacity))
            }

            // Stream badge (top-right)
            if canStream && downloadProgress == nil {
                HStack(spacing: 3) {
                    Image(systemName: streamBadgeIcon)
                        .font(.system(size: 8, weight: .bold))
                    Text(streamBadgeLabel)
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial.opacity(0.9))
                .background(server.serverType.tint.opacity(0.8))
                .clipShape(Capsule())
                .padding(6)
            }

            // Error indicator
            if let error = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.inkAmber)
                    .font(.system(size: 16))
                    .padding(8)
                    .help(error)
            }
        }
    }

    private var placeholderCover: some View {
        ZStack {
            LinearGradient(
                colors: [server.serverType.tint.opacity(0.2), server.serverType.tint.opacity(0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 6) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(server.serverType.tint.opacity(0.6))
                if let pages = entry.pageCount {
                    Text("\(pages) pages")
                        .font(.system(size: 10))
                        .foregroundStyle(server.serverType.tint.opacity(0.5))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

import SwiftUI

// MARK: - OPDS PSE Page Streaming Reader

/// Fullscreen swipe-based reader that fetches individual pages via the OPDS-PSE
/// URL template (`{pageNumber}` substitution, optional `{maxWidth}` injection).
/// Manages an NSCache sliding window of ±2 pages to prevent swipe stall.
@MainActor struct OPDSPSEReader: View {
    let server: SDOPDSServer
    let entry: OPDSEntry

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentPage: Int = 0
    @State private var pageImages: [Int: UIImage] = [:]
    @State private var pageErrors: [Int: Bool] = [:]
    @State private var showUI = true
    @State private var isLoadingInitial = true
    @State private var hideUITask: Task<Void, Never>?

    // Phase 2: Progress sync
    @State private var pagesSinceLastSync: Int = 0
    private static let syncInterval = 5   // save every N page turns

    private let cache = NSCache<NSNumber, UIImage>()
    private static let prefetchRadius = 2

    private var totalPages: Int {
        // Prefer PSE count, then page count from entry, default to 0 (unknown)
        if let url = streamURLTemplate, let countStr = url.absoluteString
            .components(separatedBy: "pse:count=").dropFirst().first?
            .components(separatedBy: "&").first,
           let count = Int(countStr) { return count }
        return entry.pageCount ?? 0
    }

    private var streamURLTemplate: URL? { entry.streamURL }

    private var progressText: String {
        totalPages > 0 ? "Page \(currentPage + 1) of \(totalPages)" : "Page \(currentPage + 1)"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoadingInitial {
                initialLoadingView
            } else {
                pageReaderView
            }

            // Overlay UI (tap to toggle)
            if showUI {
                overlayUI
            }
        }
        .statusBarHidden(!showUI)
        .persistentSystemOverlays(showUI ? .automatic : .hidden)
        .task {
            // Phase 2: load resume position from server (REST API or pse:lastRead)
            let resumePage = await OPDSProgressSyncService.shared.loadProgress(server: server, entry: entry)
            if let page = resumePage, page > 0 {
                currentPage = page
            }
            await prefetchPages(around: currentPage)
            withAnimation { isLoadingInitial = false }
        }
        .onChange(of: currentPage) { _, newPage in
            Task { await prefetchPages(around: newPage) }
            syncProgressIfNeeded(page: newPage)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                // App going to background — flush final position immediately
                Task {
                    await OPDSProgressSyncService.shared.saveProgress(
                        server: server, entry: entry, page: currentPage
                    )
                }
            }
        }
    }

    // MARK: - Page Reader

    private var pageReaderView: some View {
        TabView(selection: $currentPage) {
            ForEach(0..<max(1, totalPages > 0 ? totalPages : currentPage + 5), id: \.self) { pageIndex in
                pageView(for: pageIndex)
                    .tag(pageIndex)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // onChange is handled at the parent ZStack level (above)
        .onTapGesture { toggleUI() }
    }

    @ViewBuilder
    private func pageView(for index: Int) -> some View {
        if let img = pageImages[index] ?? cache.object(forKey: NSNumber(value: index)) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else if pageErrors[index] == true {
            pageErrorView(index)
        } else {
            pagePlaceholder(index)
                .task { await fetchPage(index) }
        }
    }

    private func pagePlaceholder(_ index: Int) -> some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.1)
                    .tint(server.serverType.tint)
                Text("Page \(index + 1)")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func pageErrorView(_ index: Int) -> some View {
        ZStack {
            Color.black
            VStack(spacing: 16) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Color.inkAmber)
                Text("Failed to load page \(index + 1)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                Button("Retry") {
                    pageErrors.removeValue(forKey: index)
                    Task { await fetchPage(index) }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(server.serverType.tint)
            }
        }
    }

    // MARK: - Overlay UI

    private var overlayUI: some View {
        VStack {
            // Top bar
            HStack {
                Button { 
                    // Save final position before dismissing
                    let page = currentPage
                    let isLast = totalPages > 0 && page >= totalPages - 1
                    Task {
                        await OPDSProgressSyncService.shared.saveProgress(
                            server: server, entry: entry,
                            page: page, completed: isLast
                        )
                    }
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.8))
                        .shadow(color: .black.opacity(0.5), radius: 4)
                }
                .buttonStyle(.plain)

                Spacer()

                VStack(spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(progressText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                // Placeholder for symmetry
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .opacity(0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.7), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            )

            Spacer()

            // Bottom progress bar
            if totalPages > 0 {
                VStack(spacing: 8) {
                    // Scrubber
                    Slider(value: Binding(
                        get: { Double(currentPage) },
                        set: { currentPage = Int($0) }
                    ), in: 0...Double(max(1, totalPages - 1)), step: 1)
                    .tint(server.serverType.tint)
                    .padding(.horizontal, 20)

                    Text("\(currentPage + 1) / \(totalPages)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.bottom, 32)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: showUI)
    }

    // MARK: - Initial Loading

    private var initialLoadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.3)
                .tint(server.serverType.tint)
            Text("Opening \"\(entry.title)\"…")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: - Page Fetching

    private func fetchPage(_ index: Int) async {
        // Already have it
        if pageImages[index] != nil || cache.object(forKey: NSNumber(value: index)) != nil { return }

        guard let url = buildPageURL(index) else {
            pageErrors[index] = true
            return
        }

        do {
            let credential = OPDSKeychainStore.load(for: server.id)
            var request = URLRequest(url: url)
            request.timeoutInterval = 20

            // Auth header
            if server.serverType == .kavita, let token = credential?.bearerToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } else if let cred = credential, !cred.username.isEmpty {
                let raw = "\(cred.username):\(cred.password)"
                if let data = raw.data(using: .utf8) {
                    request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
                }
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let image = UIImage(data: data)
            else {
                pageErrors[index] = true
                return
            }

            cache.setObject(image, forKey: NSNumber(value: index))
            pageImages[index] = image
        } catch {
            pageErrors[index] = true
            Logger.shared.log("OPDSPSEReader: failed to fetch page \(index) — \(error)", category: "OPDS", type: .warning)
        }
    }

    private func prefetchPages(around center: Int) async {
        let radius = Self.prefetchRadius
        for offset in -radius...radius {
            let page = center + offset
            guard page >= 0 else { continue }
            if totalPages > 0 { guard page < totalPages else { continue } }
            await fetchPage(page)
        }

        // Evict pages far from the current window to stay under memory budget
        let keepRange = (center - radius * 3)...(center + radius * 3)
        pageImages = pageImages.filter { keepRange.contains($0.key) }
    }

    // MARK: - URL Template

    private func buildPageURL(_ index: Int) -> URL? {
        guard let template = entry.streamURL?.absoluteString else { return nil }

        let screenWidth = Int(UIScreen.main.bounds.width * UIScreen.main.scale)
        let resolved = template
            .replacingOccurrences(of: "{pageNumber}", with: "\(index)")
            .replacingOccurrences(of: "{maxWidth}", with: "\(screenWidth)")

        return URL(string: resolved)
    }

    // MARK: - Phase 2: Progress Sync

    /// Increments the page counter and saves progress every `syncInterval` turns.
    /// Fire-and-forget — never blocks the UI.
    private func syncProgressIfNeeded(page: Int) {
        pagesSinceLastSync += 1
        guard pagesSinceLastSync >= Self.syncInterval else { return }
        pagesSinceLastSync = 0
        let isLast = totalPages > 0 && page >= totalPages - 1
        Task {
            await OPDSProgressSyncService.shared.saveProgress(
                server: server, entry: entry,
                page: page, completed: isLast
            )
        }
    }

    private func parseLastRead() -> Int? {
        // pse:lastRead is now populated by the OPDS XML parser (Phase 2).
        // OPDSProgressSyncService.loadProgress() reads this first before
        // making a REST API call, so this stub is no longer called directly.
        return entry.pseLastRead
    }

    // MARK: - UI Toggle

    private func toggleUI() {
        hideUITask?.cancel()
        withAnimation { showUI.toggle() }
        if showUI {
            // Auto-hide after 3s of inactivity
            hideUITask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation { showUI = false }
            }
        }
    }
}

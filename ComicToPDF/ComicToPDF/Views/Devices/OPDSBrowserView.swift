import SwiftUI

// MARK: - OPDS Catalog Browser

/// Recursive catalog navigator. Each level loads one OPDS feed (navigation or acquisition).
/// Navigation feeds push a new `OPDSBrowserView`; acquisition feeds show `OPDSBookGrid`.
struct OPDSBrowserView: View {
    let server: SDOPDSServer
    var feedURL: URL? = nil          // nil → use the server's root feed
    var title: String? = nil         // nil → use server name for root level

    @State private var feed: OPDSFeed?
    @State private var isLoading = true
    @State private var error: String?
    @State private var searchText: String = ""
    @State private var searchResults: OPDSFeed?
    @State private var isSearching = false

    private var displayTitle: String { title ?? server.name }

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            if isLoading {
                loadingView
            } else if let error {
                errorView(error)
            } else if let feed {
                feedContent(feed)
            }
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search \(displayTitle)")
        .onChange(of: searchText) { _, query in
            runSearch(query: query)
        }
        .task { await loadFeed() }
        .refreshable { await loadFeed() }
    }

    // MARK: - Feed Content

    @ViewBuilder
    private func feedContent(_ feed: OPDSFeed) -> some View {
        let displayFeed = searchResults ?? feed
        ScrollView {
            LazyVStack(spacing: 0) {

                // ── Navigation Links (subsections) ─────────────────────────
                if !displayFeed.navLinks.isEmpty {
                    navigationSection(displayFeed.navLinks)
                }

                // ── Acquisition Entries (actual books) ──────────────────────
                if !displayFeed.entries.isEmpty {
                    OPDSBookGrid(server: server, entries: displayFeed.entries)
                        .padding(.top, displayFeed.navLinks.isEmpty ? 0 : 8)
                }

                // ── Empty Search Results ────────────────────────────────────
                if !searchText.isEmpty && displayFeed.navLinks.isEmpty && displayFeed.entries.isEmpty {
                    Text("No results for "\(searchText)"")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.inkTextSecondary)
                        .padding(.top, 60)
                }

                // ── Pagination ─────────────────────────────────────────────
                if let nextURL = feed.nextPageURL, searchResults == nil {
                    NavigationLink(destination: OPDSBrowserView(
                        server: server, feedURL: nextURL, title: "Next Page"
                    )) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.right.circle")
                            Text("Load More")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.inkBlue)
                        .padding(.vertical, 20)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 100)
        }
    }

    // MARK: - Navigation Section

    private func navigationSection(_ links: [OPDSNavLink]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                NavigationLink(destination: OPDSBrowserView(
                    server: server,
                    feedURL: link.feedURL,
                    title: link.title
                )) {
                    HStack(spacing: 16) {
                        Image(systemName: navIcon(for: link.title))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(server.serverType.tint)
                            .frame(width: 32)

                        Text(link.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.inkTextPrimary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.inkTextSecondary.opacity(0.5))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < links.count - 1 {
                    Divider()
                        .padding(.leading, 68)
                }
            }
        }
        .background(Color.inkSurface.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.inkTextPrimary.opacity(0.07), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: - State Views

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(server.serverType.tint)
            Text("Loading catalog…")
                .font(.system(size: 14))
                .foregroundStyle(Color.inkTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.inkAmber)

            VStack(spacing: 8) {
                Text("Connection Failed")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.inkTextPrimary)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.inkTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Button("Try Again") {
                Task { await loadFeed() }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(Color.inkBlue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func loadFeed() async {
        withAnimation { isLoading = true; error = nil }
        do {
            let result = try await OPDSClient.shared.fetchFeed(server: server, url: feedURL)
            withAnimation { feed = result; isLoading = false }
            Logger.shared.log("OPDSBrowserView: loaded '\(result.title)' — \(result.navLinks.count) nav, \(result.entries.count) books", category: "OPDS")
        } catch {
            withAnimation { self.error = error.localizedDescription; isLoading = false }
            Logger.shared.log("OPDSBrowserView: load failed — \(error)", category: "OPDS", type: .error)
        }
    }

    private func runSearch(query: String) {
        guard !query.isEmpty else { searchResults = nil; return }

        Task {
            guard let searchURL = feed?.searchURL else { return }
            withAnimation { isSearching = true }
            defer { withAnimation { isSearching = false } }

            // Debounce
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            do {
                let results = try await OPDSClient.shared.search(server: server, query: query, searchURL: searchURL)
                withAnimation { searchResults = results }
            } catch {
                Logger.shared.log("OPDSBrowserView: search failed — \(error)", category: "OPDS", type: .warning)
            }
        }
    }

    // MARK: - Icon helper

    private func navIcon(for title: String) -> String {
        let lower = title.lowercased()
        if lower.contains("series") || lower.contains("collection")   { return "rectangle.stack.fill" }
        if lower.contains("recent") || lower.contains("new")          { return "clock.fill" }
        if lower.contains("reading") || lower.contains("progress")    { return "book.fill" }
        if lower.contains("library") || lower.contains("libraries")   { return "books.vertical.fill" }
        if lower.contains("author")                                    { return "person.fill" }
        if lower.contains("publisher")                                 { return "building.2.fill" }
        if lower.contains("genre") || lower.contains("tag")           { return "tag.fill" }
        if lower.contains("all")                                       { return "square.grid.2x2.fill" }
        return "folder.fill"
    }
}

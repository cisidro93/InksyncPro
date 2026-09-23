import SwiftUI

// MARK: - OPDS Catalog Browser View

public struct OPDSBrowserView: View {
    @ObservedObject private var store = OPDSServerStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedServer: OPDSServer
    @State private var currentFeed: OPDSFeed?
    @State private var feedStack: [(title: String, url: URL)] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedEntry: OPDSEntry?
    @State private var showingAddServerSheet = false
    @State private var searchText = ""

    public init(initialServer: OPDSServer? = nil) {
        let first = initialServer ?? OPDSServerStore.shared.servers.first ?? OPDSServer.standardPresets[0]
        _selectedServer = State(initialValue: first)
    }

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.05, green: 0.05, blue: 0.07).ignoresSafeArea()

                VStack(spacing: 0) {
                    serverPickerHeader

                    if isLoading && currentFeed == nil {
                        Spacer()
                        ProgressView("Connecting to OPDS Catalog...")
                            .tint(.white)
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                    } else if let err = errorMessage, currentFeed == nil {
                        errorState(message: err)
                    } else if let feed = currentFeed {
                        feedContentView(feed: feed)
                    }
                }
            }
            .navigationTitle(currentFeed?.title ?? selectedServer.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.white.opacity(0.85))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddServerSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .sheet(item: $selectedEntry) { entry in
                OPDSEntryDetailSheet(entry: entry, server: selectedServer)
            }
            .sheet(isPresented: $showingAddServerSheet) {
                AddOPDSServerSheet { newServer in
                    store.addServer(newServer)
                    selectedServer = newServer
                    loadFeed(at: newServer.url, title: newServer.name)
                }
            }
            .task {
                if currentFeed == nil {
                    loadFeed(at: selectedServer.url, title: selectedServer.name)
                }
            }
        }
    }

    // MARK: - Server Picker Header

    private var serverPickerHeader: some View {
        HStack {
            Menu {
                ForEach(store.servers) { server in
                    Button {
                        selectedServer = server
                        feedStack.removeAll()
                        loadFeed(at: server.url, title: server.name)
                    } label: {
                        HStack {
                            Text(server.name)
                            if server.id == selectedServer.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button {
                    showingAddServerSheet = true
                } label: {
                    Label("Add Custom OPDS Server...", systemImage: "plus")
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selectedServer.iconName)
                        .foregroundColor(.accentColor)
                    Text(selectedServer.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
            }

            Spacer()

            if !feedStack.isEmpty {
                Button {
                    popFeed()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Feed Content (Navigation + Publications)

    private func feedContentView(feed: OPDSFeed) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Navigation categories / subsections
                if !feed.navigationLinks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Categories & Sections")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                            .textCase(.uppercase)
                            .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(feed.navigationLinks, id: \.self) { nav in
                                    Button {
                                        if let resolved = nav.resolvedURL(relativeTo: selectedServer.url) {
                                            pushFeed(url: resolved, title: nav.title ?? "Section")
                                        }
                                    } label: {
                                        Text(nav.title ?? "Explore")
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 9)
                                            .background(.ultraThinMaterial)
                                            .clipShape(Capsule())
                                            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }

                // Books Grid
                if !feed.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Books (\(feed.entries.count))")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                            .textCase(.uppercase)
                            .padding(.horizontal, 16)

                        let columns = [
                            GridItem(.adaptive(minimum: isPad ? 160 : 110), spacing: 16)
                        ]

                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(feed.entries) { entry in
                                Button {
                                    selectedEntry = entry
                                } label: {
                                    bookGridCell(entry: entry)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                } else if feed.navigationLinks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.4))
                        Text("No books found in this section")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func bookGridCell(entry: OPDSEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                if let thumb = entry.thumbnailURL(relativeTo: selectedServer.url) {
                    AsyncImage(url: thumb) { phase in
                        switch phase {
                        case .success(let img):
                            img
                                .resizable()
                                .scaledToFill()
                                .frame(width: isPad ? 160 : 110, height: isPad ? 230 : 160)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        default:
                            placeholderCell
                        }
                    }
                } else {
                    placeholderCell
                }

                if let firstAcquisition = entry.primaryAcquisitionLink {
                    Text(firstAcquisition.formatBadge)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

            Text(entry.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)

            Text(entry.authorString)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
        }
        .frame(width: isPad ? 160 : 110)
    }

    private var placeholderCell: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .frame(width: isPad ? 160 : 110, height: isPad ? 230 : 160)
            .overlay(
                Image(systemName: "book.closed")
                    .font(.system(size: 28))
                    .foregroundColor(.white.opacity(0.3))
            )
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.yellow)
            Text("Connection Failed")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                loadFeed(at: selectedServer.url, title: selectedServer.name)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(Color.white)
            .clipShape(Capsule())
        }
        .padding(.top, 40)
    }

    // MARK: - Navigation Stack Helpers

    private func pushFeed(url: URL, title: String) {
        if let current = currentFeed {
            feedStack.append((title: current.title, url: selectedServer.url))
        }
        loadFeed(at: url, title: title)
    }

    private func popFeed() {
        guard let prev = feedStack.popLast() else { return }
        loadFeed(at: prev.url, title: prev.title)
    }

    private func loadFeed(at url: URL, title: String) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let feed = try await OPDSNetworkClient.shared.fetchFeed(from: url, server: selectedServer)
                await MainActor.run {
                    self.currentFeed = feed
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - Add Custom Server Sheet

struct AddOPDSServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdd: (OPDSServer) -> Void

    @State private var name: String = ""
    @State private var urlString: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Server Information")) {
                    TextField("Server Name (e.g. My Kavita / Komga)", text: $name)
                    TextField("OPDS URL (https://...)", text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section(header: Text("Authentication (Optional)"), footer: Text("Required for private home servers like Kavita, Komga, or Calibre-Web.")) {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password or API Key", text: $password)
                }

                if let err = errorMessage {
                    Section {
                        Text(err).foregroundColor(.red).font(.system(size: 13))
                    }
                }
            }
            .navigationTitle("Add OPDS Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .bold()
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || urlString.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            errorMessage = "Please enter a valid URL starting with http:// or https://"
            return
        }

        let newServer = OPDSServer(
            name: name.trimmingCharacters(in: .whitespaces),
            url: url,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            iconName: "server.rack"
        )
        onAdd(newServer)
        dismiss()
    }
}

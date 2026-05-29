import SwiftUI
import SwiftData

struct BetaLibraryView: View {
    @EnvironmentObject var libraryStore: BetaLibraryStore
    @EnvironmentObject var kindleService: BetaKindleService
    
    @State private var searchText = ""
    @State private var selectedFilter: BetaContentType? = nil
    @State private var sortBy: SortOption = .dateAdded
    @State private var isGridView = true
    @State private var showingImportSheet = false
    
    // Reading State
    @State private var selectedBookForReader: BetaBook? = nil
    
    enum SortOption {
        case title, dateAdded, size
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    // Header Search & Filter Bar
                    filterHeader
                    
                    if filteredBooks.isEmpty {
                        emptyStateView
                    } else {
                        if isGridView {
                            gridView
                        } else {
                            listView
                        }
                    }
                }
                
                // Import Progress Overlay
                if libraryStore.isImporting {
                    importProgressOverlay
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button {
                            isGridView.toggle()
                        } label: {
                            Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2.fill")
                                .foregroundStyle(Color.orange)
                        }
                        
                        sortMenu
                        
                        Button {
                            showingImportSheet = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.orange)
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImportSheet,
                allowedContentTypes: [.zip, .pdf, .epub, .data], // data covers .cbz / .cbr fallback
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task {
                        await libraryStore.importFiles(from: urls)
                    }
                case .failure(let error):
                    print("BetaLibraryView: File picker error: \(error)")
                }
            }
            .fullScreenCover(item: $selectedBookForReader) { book in
                BetaReaderView(book: book)
            }
        }
    }
    
    // MARK: - Filter Header
    
    private var filterHeader: some View {
        VStack(spacing: 12) {
            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.gray)
                TextField("Search titles or series...", text: $searchText)
                    .foregroundStyle(.white)
                    .tint(.orange)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.gray)
                    }
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.08))
            .cornerRadius(10)
            .padding(.horizontal)
            
            // Filter Chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // "All" Chip
                    filterChip(title: "All", isSelected: selectedFilter == nil) {
                        selectedFilter = nil
                    }
                    
                    ForEach(BetaContentType.allCases, id: \.self) { type in
                        filterChip(title: type.rawValue, isSelected: selectedFilter == type) {
                            selectedFilter = type
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 10)
        }
        .padding(.top, 10)
        .background(Color.black.opacity(0.2))
    }
    
    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.orange : Color.white.opacity(0.08))
                )
                .foregroundStyle(isSelected ? .black : .white)
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Color.white.opacity(0.1), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Sort Menu
    
    private var sortMenu: some View {
        Menu {
            Button { sortBy = .title } label: {
                Label("Title", systemImage: sortBy == .title ? "checkmark" : "")
            }
            Button { sortBy = .dateAdded } label: {
                Label("Date Added", systemImage: sortBy == .dateAdded ? "checkmark" : "")
            }
            Button { sortBy = .size } label: {
                Label("File Size", systemImage: sortBy == .size ? "checkmark" : "")
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(Color.orange)
        }
    }
    
    // MARK: - Grid View
    
    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20)], spacing: 20) {
                ForEach(sortedBooks) { book in
                    BookGridCard(book: book) {
                        selectedBookForReader = book
                    }
                }
            }
            .padding()
        }
    }
    
    // MARK: - List View
    
    private var listView: some View {
        List {
            ForEach(sortedBooks) { book in
                BookListRow(book: book) {
                    selectedBookForReader = book
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color.white.opacity(0.1))
            }
        }
        .listStyle(.plain)
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 15) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 60))
                .foregroundStyle(.gray)
            
            Text("No Books Found")
                .font(.headline)
                .foregroundStyle(.white)
            
            Text("Import digital comics, books, or PDFs to start building your personal library.")
                .font(.subheadline)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button {
                showingImportSheet = true
            } label: {
                Text("Import Files")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.orange)
                    .cornerRadius(8)
            }
            .padding(.top, 10)
            
            Spacer()
        }
    }
    
    // MARK: - Import Progress Overlay
    
    private var importProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                    .scaleEffect(1.5)
                
                Text("Importing library documents...")
                    .font(.headline)
                    .foregroundStyle(.white)
                
                ProgressView(value: libraryStore.importProgress)
                    .accentColor(.orange)
                    .frame(width: 250)
                
                Text("\(Int(libraryStore.importProgress * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }
            .padding(30)
            .background(Color(hex: "#1E1E24"))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
    }
    
    // MARK: - Filter and Sort Helpers
    
    private var filteredBooks: [BetaBook] {
        libraryStore.books.filter { book in
            let matchesSearch = searchText.isEmpty ||
                book.title.localizedCaseInsensitiveContains(searchText) ||
                (book.seriesName?.localizedCaseInsensitiveContains(searchText) ?? false)
            
            let matchesFilter = selectedFilter == nil || book.contentType == selectedFilter
            
            return matchesSearch && matchesFilter
        }
    }
    
    private var sortedBooks: [BetaBook] {
        filteredBooks.sorted { a, b in
            switch sortBy {
            case .title:
                return a.title.localizedCompare(b.title) == .orderedAscending
            case .dateAdded:
                return a.dateAdded > b.dateAdded
            case .size:
                return a.fileSize > b.fileSize
            }
        }
    }
}

// MARK: - Book Cover Thumbnail Loader

struct BetaBookCoverView: View {
    let book: BetaBook
    @EnvironmentObject var libraryStore: BetaLibraryStore
    
    var body: some View {
        Group {
            if let coverURL = libraryStore.coverURL(for: book),
               let uiImage = UIImage(contentsOfFile: coverURL.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // Placeholder
                ZStack {
                    LinearGradient(colors: [book.contentType.themeColor.opacity(0.2), book.contentType.themeColor.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    
                    VStack(spacing: 8) {
                        Image(systemName: book.contentType.icon)
                            .font(.system(size: 30))
                            .foregroundStyle(book.contentType.themeColor)
                        
                        Text(book.contentType.rawValue.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(book.contentType.themeColor)
                    }
                }
            }
        }
    }
}

// MARK: - Book Grid Card Component

struct BookGridCard: View {
    let book: BetaBook
    let action: () -> Void
    @EnvironmentObject var libraryStore: BetaLibraryStore
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // Cover Art Card
                BetaBookCoverView(book: book)
                    .frame(height: 200)
                    .clipped()
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(radius: 5)
                
                // Book Title
                Text(book.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 36, alignment: .topLeading)
                
                // Progress Bar and Type Badge
                HStack {
                    Text(book.contentType.rawValue)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(book.contentType.themeColor.opacity(0.2))
                        .foregroundStyle(book.contentType.themeColor)
                        .cornerRadius(4)
                    
                    Spacer()
                    
                    if book.currentPage > 0 {
                        Text("\(Int(book.progressPercent * 100))% read")
                            .font(.system(size: 10))
                            .foregroundStyle(.gray)
                    } else {
                        Text("Unread")
                            .font(.system(size: 10))
                            .foregroundStyle(.gray)
                    }
                }
                
                if book.currentPage > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            Capsule().fill(book.contentType.themeColor)
                                .frame(width: geo.size.width * book.progressPercent)
                        }
                    }
                    .frame(height: 3)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                withAnimation {
                    libraryStore.deleteBook(book)
                }
            } label: {
                Label("Delete Book", systemImage: "trash")
            }
        }
    }
}

// MARK: - Book List Row Component

struct BookListRow: View {
    let book: BetaBook
    let action: () -> Void
    @EnvironmentObject var libraryStore: BetaLibraryStore
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                BetaBookCoverView(book: book)
                    .frame(width: 50, height: 70)
                    .clipped()
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    
                    HStack(spacing: 10) {
                        Text(book.contentType.rawValue)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(book.contentType.themeColor.opacity(0.2))
                            .foregroundStyle(book.contentType.themeColor)
                            .cornerRadius(4)
                        
                        Text(book.formattedSize)
                            .font(.system(size: 11))
                            .foregroundStyle(.gray)
                        
                        if book.currentPage > 0 {
                            Text("•  \(Int(book.progressPercent * 100))% read")
                                .font(.system(size: 11))
                                .foregroundStyle(.gray)
                        }
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(.gray)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                withAnimation {
                    libraryStore.deleteBook(book)
                }
            } label: {
                Label("Delete Book", systemImage: "trash")
            }
        }
    }
}

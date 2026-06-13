import SwiftUI

struct MetadataSearchSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    
    let pdf: ConvertedPDF
    // Service is now a singleton
    
    enum MetadataProvider: String, CaseIterable, Identifiable {
        case comicVine = "ComicVine"
        case aniList = "AniList"
        case mangaUpdates = "MangaUpdates"
        case googleBooks = "Google Books"
        
        var id: String { rawValue }
    }
    
    @State private var query = ""
    @State private var selectedProvider: MetadataProvider = .comicVine
    @State private var comicResults: [ComicVineVolume] = []
    @State private var bookResults: [GoogleBookItem] = []
    @State private var mangaResults: [AniListManga] = []
    @State private var mangaUpdatesResults: [MangaUpdatesManga] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingErrorAlert = false
    
    var body: some View {
        NavigationStack {
            VStack {
                // Search Bar
                HStack {
                    TextField((selectedProvider == .aniList || selectedProvider == .mangaUpdates) ? "Manga Name (e.g. Naruto)" : "Series Name (e.g. Saga)", text: $query)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onSubmit { performSearch() }
                    
                    Button(action: performSearch) {
                        Image(systemName: "magnifyingglass")
                            .padding(8)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal)
                .padding(.top)
                
                // Segmented Picker for Metadata Source
                Picker("Metadata Source", selection: $selectedProvider) {
                    ForEach(MetadataProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                
                // API Key Warning (Only pertinent to ComicVine)
                if selectedProvider == .comicVine && settingsManager.conversionSettings.comicVineAPIKey.isEmpty {
                    Text("⚠️ Please set ComicVine API Key in Settings")
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.bottom)
                }
                
                // Results List
                if isLoading {
                    ProgressView()
                    Spacer()
                } else {
                    switch selectedProvider {
                    case .googleBooks:
                        List(bookResults) { book in
                            Button(action: { selectBook(book) }) {
                                HStack {
                                    if let urlStr = book.volumeInfo.imageLinks?.bestQualityURL,
                                       let url = URL(string: urlStr) {
                                        AsyncImage(url: url) { phase in
                                            if let image = phase.image {
                                                image.resizable().aspectRatio(contentMode: .fit)
                                            } else {
                                                Color.gray.frame(width: 55, height: 75)
                                            }
                                        }
                                        .frame(width: 50, height: 75)
                                        .cornerRadius(4)
                                    } else {
                                        Rectangle().fill(Color.gray).frame(width: 50, height: 75)
                                            .overlay(Image(systemName: "book.closed").foregroundColor(.white))
                                    }
                                    
                                    VStack(alignment: .leading) {
                                        Text(book.volumeInfo.title).font(.headline)
                                        if let authors = book.volumeInfo.authors {
                                            Text(authors.joined(separator: ", ")).font(.caption).foregroundColor(.secondary)
                                        }
                                        if let publisher = book.volumeInfo.publisher {
                                            Text(publisher).font(.caption2).foregroundColor(.gray)
                                        }
                                    }
                                }
                            }
                            .listRowBackground(Color.inkSurface.opacity(0.4))
                        }
                        .scrollContentBackground(.hidden)
                        
                    case .aniList:
                        List(mangaResults) { manga in
                            Button(action: { selectManga(manga) }) {
                                HStack {
                                    if let urlStr = manga.coverImage?.bestImageURL,
                                       let url = URL(string: urlStr) {
                                        AsyncImage(url: url) { phase in
                                            if let image = phase.image {
                                                image.resizable().aspectRatio(contentMode: .fit)
                                            } else {
                                                Color.gray.frame(width: 55, height: 75)
                                            }
                                        }
                                        .frame(width: 50, height: 75)
                                        .cornerRadius(4)
                                    } else {
                                        Rectangle().fill(Color.gray).frame(width: 50, height: 75)
                                            .overlay(Image(systemName: "text.book.closed").foregroundColor(.white))
                                    }
                                    
                                    VStack(alignment: .leading) {
                                        Text(manga.title.preferredTitle).font(.headline)
                                        if let creators = manga.creatorNames {
                                            Text(creators).font(.caption).foregroundColor(.secondary)
                                        }
                                        HStack {
                                            if let format = manga.format {
                                                Text(format).font(.caption2).foregroundColor(.gray)
                                            }
                                            if let date = manga.startDate, let year = date.year {
                                                Text("(\(String(year)))").font(.caption2).foregroundColor(.gray)
                                            }
                                        }
                                    }
                                }
                            }
                            .listRowBackground(Color.inkSurface.opacity(0.4))
                        }
                        .scrollContentBackground(.hidden)
                        
                    case .mangaUpdates:
                        List(mangaUpdatesResults) { manga in
                            Button(action: { selectMangaUpdates(manga) }) {
                                HStack {
                                    if let urlStr = manga.image?.url?.thumb ?? manga.image?.url?.original,
                                       let url = URL(string: urlStr) {
                                        AsyncImage(url: url) { phase in
                                            if let image = phase.image {
                                                image.resizable().aspectRatio(contentMode: .fit)
                                            } else {
                                                Color.gray.frame(width: 55, height: 75)
                                            }
                                        }
                                        .frame(width: 50, height: 75)
                                        .cornerRadius(4)
                                    } else {
                                        Rectangle().fill(Color.gray).frame(width: 50, height: 75)
                                            .overlay(Image(systemName: "text.book.closed").foregroundColor(.white))
                                    }
                                    
                                    VStack(alignment: .leading) {
                                        Text(manga.title).font(.headline)
                                        HStack {
                                            if let format = manga.type {
                                                Text(format).font(.caption2).foregroundColor(.gray)
                                            }
                                            if let year = manga.year, !year.isEmpty {
                                                Text("(\(year))").font(.caption2).foregroundColor(.gray)
                                            }
                                        }
                                        if let genres = manga.genres, !genres.isEmpty {
                                            Text(genres.map { $0.genre }.joined(separator: ", "))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            }
                            .listRowBackground(Color.inkSurface.opacity(0.4))
                        }
                        .scrollContentBackground(.hidden)
                        
                    case .comicVine:
                        List(comicResults) { volume in
                            Button(action: { selectVolume(volume) }) {
                                HStack {
                                    AsyncImage(url: URL(string: volume.image?.icon_url ?? "")) { phase in
                                        if let image = phase.image {
                                            image.resizable().aspectRatio(contentMode: .fit)
                                        } else {
                                            Color.gray.frame(width: 55, height: 75)
                                        }
                                    }
                                    .frame(width: 50, height: 75)
                                    .cornerRadius(4)
                                    
                                    VStack(alignment: .leading) {
                                        Text(volume.name).font(.headline)
                                        Text(volume.publisher?.name ?? "Unknown Publisher").font(.caption).foregroundColor(.secondary)
                                        if let year = volume.start_year {
                                            Text(year).font(.caption2).foregroundColor(.gray)
                                        }
                                    }
                                }
                            }
                            .listRowBackground(Color.inkSurface.opacity(0.4))
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .background(Color.inkBackground.ignoresSafeArea())
            .navigationTitle("Find Series")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
            }
            .alert("Search Error", isPresented: $showingErrorAlert, presenting: errorMessage) { _ in
                Button("OK", role: .cancel) { }
            } message: { msg in
                Text(msg)
            }
            .onAppear {
                // Pre-fill query with filename
                query = cleanFilename(pdf.name)
                
                // Select default provider based on content type or format
                if pdf.contentType == .manga {
                    selectedProvider = .aniList
                } else if pdf.contentType == .book || pdf.url.pathExtension.lowercased() == "epub" {
                    selectedProvider = .googleBooks
                } else {
                    selectedProvider = .comicVine
                }
            }
        }
    }
    
    func performSearch() {
        guard !query.isEmpty else { return }
        
        isLoading = true
        errorMessage = nil
        
        switch selectedProvider {
        case .googleBooks:
            Task {
                do {
                    bookResults = try await BookMetadataService.shared.searchBooks(query: query)
                    await MainActor.run { isLoading = false }
                } catch {
                    Logger.shared.log("Google Books Search Failed: \(error.localizedDescription)", category: "Metadata", type: .error)
                    await MainActor.run {
                        isLoading = false
                        errorMessage = error.localizedDescription
                        showingErrorAlert = true
                    }
                }
            }
            
        case .aniList:
            let token = settingsManager.conversionSettings.aniListAPIToken
            Task {
                do {
                    mangaResults = try await AniListService.shared.searchManga(query: query, apiToken: token)
                    await MainActor.run { isLoading = false }
                } catch {
                    Logger.shared.log("AniList Search Failed: \(error.localizedDescription)", category: "Metadata", type: .error)
                    await MainActor.run {
                        isLoading = false
                        errorMessage = error.localizedDescription
                        showingErrorAlert = true
                    }
                }
            }
            
        case .mangaUpdates:
            let username = settingsManager.conversionSettings.mangaUpdatesUsername
            let password = settingsManager.conversionSettings.mangaUpdatesPassword
            Task {
                do {
                    mangaUpdatesResults = try await MangaUpdatesService.shared.searchManga(query: query, username: username, password: password)
                    await MainActor.run { isLoading = false }
                } catch {
                    Logger.shared.log("MangaUpdates Search Failed: \(error.localizedDescription)", category: "Metadata", type: .error)
                    await MainActor.run {
                        isLoading = false
                        errorMessage = error.localizedDescription
                        showingErrorAlert = true
                    }
                }
            }
            
        case .comicVine:
            let key = settingsManager.conversionSettings.comicVineAPIKey
            guard !key.isEmpty else {
                isLoading = false
                errorMessage = "ComicVine API Key is required. Please set it in Preferences."
                showingErrorAlert = true
                return
            }
            
            Task {
                do {
                    comicResults = try await ComicVineService.shared.searchVolumes(query: query, apiKey: key)
                    await MainActor.run { isLoading = false }
                } catch {
                    Logger.shared.log("ComicVine Search Failed: \(error.localizedDescription)", category: "Metadata", type: .error)
                    await MainActor.run {
                        isLoading = false
                        errorMessage = error.localizedDescription
                        showingErrorAlert = true
                    }
                }
            }
        }
    }
    
    func selectBook(_ book: GoogleBookItem) {
        isLoading = true
        Task {
            await MainActor.run {
                var newMeta = pdf.metadata
                newMeta.title = book.volumeInfo.title
                newMeta.series = book.volumeInfo.subtitle
                newMeta.publisher = book.volumeInfo.publisher
                
                if let authors = book.volumeInfo.authors {
                    newMeta.writer = authors.joined(separator: ", ")
                }
                
                if let desc = book.volumeInfo.description {
                    newMeta.summary = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: String.CompareOptions.regularExpression, range: nil)
                }
                
                if let dateString = book.volumeInfo.publishedDate {
                    let formatter = DateFormatter()
                    formatter.dateFormat = dateString.count == 4 ? "yyyy" : (dateString.count == 7 ? "yyyy-MM" : "yyyy-MM-dd")
                    newMeta.publicationDate = formatter.date(from: dateString)
                }
                
                newMeta.tags.append("Google Books")
                conversionManager.updatePDFMetadata(pdf, metadata: newMeta)
                
                if let urlStr = book.volumeInfo.imageLinks?.bestQualityURL {
                    Task {
                        await fetchAndSaveCover(urlStr)
                        await MainActor.run {
                            isLoading = false
                            dismiss()
                        }
                    }
                } else {
                    isLoading = false
                    dismiss()
                }
            }
        }
    }
    
    func selectManga(_ manga: AniListManga) {
        isLoading = true
        let originalSeries = pdf.metadata.series // Capture original to identify siblings
        Task {
            await MainActor.run {
                var newMeta = pdf.metadata
                newMeta.series = manga.title.preferredTitle
                newMeta.tags.append("AniList")
                newMeta.isManga = true
                
                if let creators = manga.creatorNames {
                    newMeta.writer = creators
                    newMeta.author = creators
                }
                
                if let desc = manga.description {
                    newMeta.summary = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: String.CompareOptions.regularExpression, range: nil)
                }
                
                if let date = manga.startDate?.toDate {
                    newMeta.publicationDate = date
                }
                
                newMeta.externalSeriesID = "anilist:\(manga.id)"
                
                // Keep the existing issue/volume values if present
                if let issueString = extractIssueNumber(from: pdf.name) {
                    newMeta.volume = issueString
                    newMeta.issueNumber = issueString
                    newMeta.title = "\(manga.title.preferredTitle) #\(issueString)"
                } else {
                    newMeta.title = manga.title.preferredTitle
                }
                
                conversionManager.updatePDFMetadata(pdf, metadata: newMeta)
                
                // Trigger background metadata propagation for sister volumes
                intelligentFetchRelatedManga(for: manga, originalSeries: originalSeries)
                
                if let urlStr = manga.coverImage?.bestImageURL {
                    Task {
                        await fetchAndSaveCover(urlStr)
                        await MainActor.run {
                            isLoading = false
                            dismiss()
                        }
                    }
                } else {
                    isLoading = false
                    dismiss()
                }
            }
        }
    }
    
    func selectMangaUpdates(_ manga: MangaUpdatesManga) {
        isLoading = true
        let originalSeries = pdf.metadata.series // Capture original to identify siblings
        let username = settingsManager.conversionSettings.mangaUpdatesUsername
        let password = settingsManager.conversionSettings.mangaUpdatesPassword
        
        Task {
            do {
                let details = try await MangaUpdatesService.shared.getSeries(id: manga.id, username: username, password: password)
                
                await MainActor.run {
                    var newMeta = pdf.metadata
                    newMeta.series = details.title
                    newMeta.tags.append("MangaUpdates")
                    newMeta.isManga = true
                    
                    if let type = details.type {
                        newMeta.tags.append(type)
                    }
                    
                    if let authors = details.authors {
                        let writers = authors.filter { $0.type.lowercased() == "author" }.map { $0.name }.joined(separator: ", ")
                        let artists = authors.filter { $0.type.lowercased() == "artist" }.map { $0.name }.joined(separator: ", ")
                        newMeta.writer = writers.isEmpty ? nil : writers
                        newMeta.author = writers.isEmpty ? nil : writers
                        newMeta.penciller = artists.isEmpty ? nil : artists
                    }
                    
                    if let publishers = details.publishers {
                        let engPublishers = publishers.filter { $0.type.lowercased() == "english" }.map { $0.publisher_name }.joined(separator: ", ")
                        let origPublishers = publishers.filter { $0.type.lowercased() == "original" }.map { $0.publisher_name }.joined(separator: ", ")
                        newMeta.publisher = engPublishers.isEmpty ? (origPublishers.isEmpty ? nil : origPublishers) : engPublishers
                    }
                    
                    if let desc = details.description {
                        newMeta.summary = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: String.CompareOptions.regularExpression, range: nil)
                    }
                    
                    if let year = details.year, let y = Int(year) {
                        var comps = DateComponents()
                        comps.year = y
                        comps.month = 1
                        comps.day = 1
                        newMeta.publicationDate = Calendar.current.date(from: comps)
                    }
                    
                    newMeta.externalSeriesID = "mangaupdates:\(details.id)"
                    
                    if let issueString = extractIssueNumber(from: pdf.name) {
                        newMeta.volume = issueString
                        newMeta.issueNumber = issueString
                        newMeta.title = "\(details.title) #\(issueString)"
                    } else {
                        newMeta.title = details.title
                    }
                    
                    conversionManager.updatePDFMetadata(pdf, metadata: newMeta)
                    
                    intelligentFetchRelatedMangaUpdates(for: details, originalSeries: originalSeries)
                    
                    if let urlStr = details.image?.url?.original ?? details.image?.url?.thumb {
                        Task {
                            await fetchAndSaveCover(urlStr)
                            await MainActor.run {
                                isLoading = false
                                dismiss()
                            }
                        }
                    } else {
                        isLoading = false
                        dismiss()
                    }
                }
            } catch {
                Logger.shared.log("MangaUpdates Details Fetch Failed: \(error.localizedDescription)", category: "Metadata", type: .error)
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                    showingErrorAlert = true
                }
            }
        }
    }
    
    func selectVolume(_ volume: ComicVineVolume) {
        isLoading = true
        let originalSeries = pdf.metadata.series // Capture original to identify siblings
        Task {
            let key = settingsManager.conversionSettings.comicVineAPIKey
            do {
                // Try to guess issue number
                if let issueNum = extractIssueNumber(from: pdf.name) {
                     if let issue = try await ComicVineService.shared.getIssue(volumeID: volume.id, issueNumber: issueNum, apiKey: key) {
                          await applyIssueMetadata(issue, volume: volume)
                          // Trigger intelligent background fetch
                          intelligentFetchRelatedIssues(for: volume, originalSeries: originalSeries)
                          return
                     }
                }
                
                // Fallback: Just apply Series info
                await applySeriesMetadata(volume)
                // Trigger intelligent background fetch
                intelligentFetchRelatedIssues(for: volume, originalSeries: originalSeries)
            } catch {
                Logger.shared.log("Metadata Fetch Failed: \(error.localizedDescription)", category: "Metadata", type: .error)
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                    showingErrorAlert = true
                }
            }
        }
    }
    
    func applyIssueMetadata(_ issue: ComicVineIssueDetails, volume: ComicVineVolume) async {
        await MainActor.run {
            var newMeta = pdf.metadata
            newMeta.title = issue.name ?? newMeta.title // Issues often don't have names, keeping old might be better or use Series #Num
            newMeta.series = volume.name
            newMeta.volume = issue.issue_number ?? newMeta.volume
            newMeta.issueNumber = issue.issue_number
            newMeta.publisher = volume.publisher?.name
            
            // Fix: Parse Date String (YYYY-MM-DD)
            if let dateString = issue.cover_date {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                newMeta.publicationDate = formatter.date(from: dateString)
            }
            
            newMeta.summary = issue.description?.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil) ?? ""
            newMeta.tags.append("ComicVine")
            
            if let credits = issue.person_credits {
                let writers = credits.filter { $0.role?.contains("Writer") ?? false }.compactMap { $0.name }.joined(separator: ", ")
                let pencillers = credits.filter { ($0.role?.contains("Penciller") ?? false) || ($0.role?.contains("Artist") ?? false) }.compactMap { $0.name }.joined(separator: ", ")
                newMeta.writer = writers.isEmpty ? nil : writers
                newMeta.penciller = pencillers.isEmpty ? nil : pencillers
            }
            
            conversionManager.updatePDFMetadata(pdf, metadata: newMeta)
             // Fetch cover if available?
             if let url = issue.image?.original_url {
                 Task {
                     await fetchAndSaveCover(url)
                     await MainActor.run {
                         isLoading = false
                         dismiss()
                     }
                 }
             } else {
                 isLoading = false
                 dismiss()
             }
        }
    }
    
    func applySeriesMetadata(_ volume: ComicVineVolume) async {
        await MainActor.run {
            var newMeta = pdf.metadata
            newMeta.series = volume.name
            newMeta.publisher = volume.publisher?.name
            newMeta.tags.append("ComicVine")
            
            conversionManager.updatePDFMetadata(pdf, metadata: newMeta)
            
            if let url = volume.image?.original_url {
                Task {
                    await fetchAndSaveCover(url)
                    await MainActor.run {
                        isLoading = false
                        dismiss()
                    }
                }
            } else {
                isLoading = false
                dismiss()
            }
        }
    }
    
    func fetchAndSaveCover(_ urlString: String) async {
        guard let url = URL(string: urlString) else { return }
        
        let result = await Task.detached(priority: .userInitiated) { () -> (URL, UUID)? in
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data),
                  let jpegData = image.jpegData(compressionQuality: 0.9) else { return nil }
            
            guard image.size.width > 20 && image.size.height > 20 else { return nil }
            
            let variantID = UUID()
            let coversDir = await ConversionManager.getCoversDirectory()
            let variantURL = coversDir.appendingPathComponent("\(variantID.uuidString).jpg")
            do {
                try jpegData.write(to: variantURL)
                return (variantURL, variantID)
            } catch {
                return nil
            }
        }.value
        
        if let (variantURL, variantID) = result {
            await MainActor.run {
                if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                    conversionManager.convertedPDFs[idx].metadata.coverVariants[variantID] = variantURL
                    conversionManager.convertedPDFs[idx].metadata.selectedCoverID = variantID
                    conversionManager.saveLibrary()
                }
            }
        }
    }
    
    // MARK: - Intelligent Series Fetch
    // Silently updates metadata for all other files that shared the same original series grouping.
    private func intelligentFetchRelatedIssues(for volume: ComicVineVolume, originalSeries: String?) {
        guard let oldSeriesName = originalSeries, !oldSeriesName.isEmpty else { return }
        
        let relatedFiles = conversionManager.convertedPDFs.filter {
            $0.metadata.series == oldSeriesName && $0.id != pdf.id
        }
        guard !relatedFiles.isEmpty else { return }
        
        let apiKey = settingsManager.conversionSettings.comicVineAPIKey
        let managerInfo = conversionManager // Explicit capture for the Task
        
        Task.detached(priority: .background) {
            for relatedPdf in relatedFiles {
                var newMeta = relatedPdf.metadata
                
                // Always inherit the series data
                newMeta.series = volume.name
                newMeta.publisher = volume.publisher?.name
                if !newMeta.tags.contains("ComicVine") {
                    newMeta.tags.append("ComicVine")
                }
                
                // Try to fetch specific issue data
                if let issueString = MetadataHeuristics.extractIssueNumber(from: relatedPdf.name),
                   let issue = try? await ComicVineService.shared.getIssue(volumeID: volume.id, issueNumber: issueString, apiKey: apiKey) {
                    
                    newMeta.title = issue.name ?? newMeta.title
                    newMeta.volume = issue.issue_number ?? newMeta.volume
                    newMeta.issueNumber = issue.issue_number
                    
                    if let dateString = issue.cover_date {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM-dd"
                        newMeta.publicationDate = formatter.date(from: dateString)
                    }
                    if let desc = issue.description {
                        newMeta.summary = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
                    }
                    if let credits = issue.person_credits {
                        let writers = credits.filter { $0.role?.contains("Writer") ?? false }.compactMap { $0.name }.joined(separator: ", ")
                        let pencillers = credits.filter { ($0.role?.contains("Penciller") ?? false) || ($0.role?.contains("Artist") ?? false) }.compactMap { $0.name }.joined(separator: ", ")
                        newMeta.writer = writers.isEmpty ? nil : writers
                        newMeta.penciller = pencillers.isEmpty ? nil : pencillers
                    }
                }
                
                // Apply update on MainActor immediately so UI reflects it
                let finalMeta = newMeta
                await MainActor.run {
                    managerInfo.updatePDFMetadata(relatedPdf, metadata: finalMeta)
                }
            }
        }
    }
    
    // MARK: - Intelligent Manga Series Fetch
    // Silently updates metadata for all other files that shared the same original series grouping,
    // avoiding unnecessary network calls by using the already-loaded AniList record.
    private func intelligentFetchRelatedManga(for manga: AniListManga, originalSeries: String?) {
        guard let oldSeriesName = originalSeries, !oldSeriesName.isEmpty else { return }
        
        let relatedFiles = conversionManager.convertedPDFs.filter {
            $0.metadata.series == oldSeriesName && $0.id != pdf.id
        }
        guard !relatedFiles.isEmpty else { return }
        
        let managerInfo = conversionManager
        
        Task { @MainActor in
            for relatedPdf in relatedFiles {
                var newMeta = relatedPdf.metadata
                
                newMeta.series = manga.title.preferredTitle
                newMeta.isManga = true
                if !newMeta.tags.contains("AniList") {
                    newMeta.tags.append("AniList")
                }
                
                if let creators = manga.creatorNames {
                    newMeta.writer = creators
                    newMeta.author = creators
                }
                
                if let desc = manga.description {
                    newMeta.summary = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: String.CompareOptions.regularExpression, range: nil)
                }
                
                if let date = manga.startDate?.toDate {
                    newMeta.publicationDate = date
                }
                
                newMeta.externalSeriesID = "anilist:\(manga.id)"
                
                // Dynamically format title and issue numbers based on clean filename numbers
                if let issueString = extractIssueNumber(from: relatedPdf.name) {
                    newMeta.volume = issueString
                    newMeta.issueNumber = issueString
                    newMeta.title = "\(manga.title.preferredTitle) #\(issueString)"
                } else {
                    newMeta.title = manga.title.preferredTitle
                }
                
                managerInfo.updatePDFMetadata(relatedPdf, metadata: newMeta)
            }
        }
    }
    
    // MARK: - Intelligent MangaUpdates Series Fetch
    // Silently updates metadata for all other files that shared the same original series grouping,
    // avoiding unnecessary network calls by using the already-loaded MangaUpdates record.
    private func intelligentFetchRelatedMangaUpdates(for details: MangaUpdatesSeriesDetails, originalSeries: String?) {
        guard let oldSeriesName = originalSeries, !oldSeriesName.isEmpty else { return }
        
        let relatedFiles = conversionManager.convertedPDFs.filter {
            $0.metadata.series == oldSeriesName && $0.id != pdf.id
        }
        guard !relatedFiles.isEmpty else { return }
        
        let managerInfo = conversionManager
        
        Task { @MainActor in
            for relatedPdf in relatedFiles {
                var newMeta = relatedPdf.metadata
                
                newMeta.series = details.title
                newMeta.isManga = true
                if !newMeta.tags.contains("MangaUpdates") {
                    newMeta.tags.append("MangaUpdates")
                }
                
                if let type = details.type, !newMeta.tags.contains(type) {
                    newMeta.tags.append(type)
                }
                
                if let authors = details.authors {
                    let writers = authors.filter { $0.type.lowercased() == "author" }.map { $0.name }.joined(separator: ", ")
                    let artists = authors.filter { $0.type.lowercased() == "artist" }.map { $0.name }.joined(separator: ", ")
                    newMeta.writer = writers.isEmpty ? nil : writers
                    newMeta.author = writers.isEmpty ? nil : writers
                    newMeta.penciller = artists.isEmpty ? nil : artists
                }
                
                if let publishers = details.publishers {
                    let engPublishers = publishers.filter { $0.type.lowercased() == "english" }.map { $0.publisher_name }.joined(separator: ", ")
                    let origPublishers = publishers.filter { $0.type.lowercased() == "original" }.map { $0.publisher_name }.joined(separator: ", ")
                    newMeta.publisher = engPublishers.isEmpty ? (origPublishers.isEmpty ? nil : origPublishers) : engPublishers
                }
                
                if let desc = details.description {
                    newMeta.summary = desc.replacingOccurrences(of: "<[^>]+>", with: "", options: String.CompareOptions.regularExpression, range: nil)
                }
                
                if let year = details.year, let y = Int(year) {
                    var comps = DateComponents()
                    comps.year = y
                    comps.month = 1
                    comps.day = 1
                    newMeta.publicationDate = Calendar.current.date(from: comps)
                }
                
                newMeta.externalSeriesID = "mangaupdates:\(details.id)"
                
                // Dynamically format title and issue numbers based on clean filename numbers
                if let issueString = extractIssueNumber(from: relatedPdf.name) {
                    newMeta.volume = issueString
                    newMeta.issueNumber = issueString
                    newMeta.title = "\(details.title) #\(issueString)"
                } else {
                    newMeta.title = details.title
                }
                
                managerInfo.updatePDFMetadata(relatedPdf, metadata: newMeta)
            }
        }
    }
    
    // MARK: - Helpers
    func cleanFilename(_ name: String) -> String {
        return MetadataHeuristics.cleanFilename(name)
    }
    
    func extractIssueNumber(from name: String) -> String? {
        return MetadataHeuristics.extractIssueNumber(from: name)
    }
}

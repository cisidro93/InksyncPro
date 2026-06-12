import SwiftUI

struct EventResolutionSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    let eventName: String
    @State var resolvedItems: [ResolvedEventItem]
    
    @State private var showingConfirmation = false
    @State private var isProcessing = false
    @State private var manualAssigningItem: ResolvedEventItem? = nil
    @State private var showSeriesPicker = false
    
    var autoMatched: [ResolvedEventItem] { resolvedItems.filter { if case .matched = $0.resolution { return true }; return false } }
    var suggested: [ResolvedEventItem] { resolvedItems.filter { if case .suggested = $0.resolution { return true }; return false } }
    var missing: [ResolvedEventItem] { resolvedItems.filter { if case .missing = $0.resolution { return true }; return false } }
    
    var omnibusTotalMB: Int {
        let bytes = resolvedItems.compactMap { item -> Int64? in
            if case .matched(let p) = item.resolution { return p.fileSize }
            return nil
        }.reduce(0, +)
        return Int(bytes / 1024 / 1024)
    }
    
    /// All distinct series names found in the resolved items
    var distinctSeriesInList: [String] {
        let allSeries = resolvedItems.compactMap { item -> String? in
            let s = item.request.series.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        return Array(Set(allSeries)).sorted()
    }
    
    var isMultiSeries: Bool {
        distinctSeriesInList.count > 1
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Total Required: \(resolvedItems.count)").font(.footnote).foregroundColor(.secondary)
                        HStack(spacing: 12) {
                            Label("\(autoMatched.count) Matched", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                            Label("\(suggested.count) Review", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Label("\(missing.count) Missing", systemImage: "xmark.circle.fill").foregroundColor(.red)
                        }
                        .font(.caption)
                        
                        if !suggested.isEmpty {
                            Button(action: acceptAllSuggestions) {
                                Label("Accept All \(suggested.count) Suggestions", systemImage: "checkmark.circle")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.green)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                if !suggested.isEmpty {
                    Section(header: Text("Action Required (Suggestions)").foregroundColor(.orange)) {
                        ForEach(suggested.indices, id: \.self) { index in
                            let item = suggested[index]
                            if case .suggested(let pdf) = item.resolution {
                                ResolutionItemSuggestionCell(
                                    item: item,
                                    pdf: pdf,
                                    onConfirm: { confirmSuggestion(item: item, with: pdf) },
                                    onDeny: { rejectSuggestion(item: item) },
                                    onManualMap: { manualAssigningItem = item }
                                )
                            }
                        }
                    }
                }
                
                if !autoMatched.isEmpty {
                    Section(header: Text("Auto-Matched").foregroundColor(.green)) {
                        ForEach(autoMatched) { item in
                            if case .matched(let pdf) = item.resolution {
                                Button {
                                    manualAssigningItem = item
                                } label: {
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                        VStack(alignment: .leading) {
                                            Text(pdf.name).font(.subheadline).foregroundColor(.primary)
                                            Text(item.request.originalText).font(.caption2).foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .foregroundColor(Color(.tertiaryLabel))
                                            .font(.caption)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                
                if !missing.isEmpty {
                    Section(header: Text("Missing (Still Need)").foregroundColor(.red)) {
                        ForEach(missing) { item in
                            Button {
                                manualAssigningItem = item
                            } label: {
                                HStack {
                                    Image(systemName: "xmark.circle").foregroundColor(.red)
                                    VStack(alignment: .leading) {
                                        Text(item.request.originalText).font(.subheadline).foregroundColor(.primary)
                                        if let isOpt = item.request.isOptional, isOpt {
                                            Text("Optional").font(.caption2).padding(.horizontal, 4).padding(.vertical, 2).background(Color.secondary.opacity(0.2)).cornerRadius(4)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(Color(.tertiaryLabel))
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Event Resolution")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Menu("Complete Build") {
                        Button {
                            buildEventCollection()
                        } label: {
                            Label("Create Playlist Folder", systemImage: "folder.fill")
                        }
                        
                        if isMultiSeries {
                            // Multi-series CSV: auto-organize each series
                            Button {
                                buildMultiSeriesVolumes()
                            } label: {
                                Label("Auto-Organize All \(distinctSeriesInList.count) Series", systemImage: "folder.badge.plus")
                            }
                        } else {
                            // Single-series CSV: let user pick target
                            Button {
                                showSeriesPicker = true
                            } label: {
                                Label("Organize into Volume Folders", systemImage: "folder.badge.plus")
                            }
                        }
                        
                        Divider()
                        
                        Button {
                            buildOmnibusSequence()
                        } label: {
                            Label("Compile Kindle Omnibus (\(omnibusTotalMB)MB)", systemImage: "books.vertical.fill")
                        }
                        Button {
                            applyMetadataTags()
                        } label: {
                            Label("Inject Native Metadata Tags", systemImage: "tag.fill")
                        }
                    }
                    .font(.headline)
                    .disabled(autoMatched.isEmpty && suggested.isEmpty)
                }
            }
            .sheet(item: $manualAssigningItem) { item in
                LibraryFilePickerSheet { selectedPDF in
                    manualAssigningItem = nil
                    if let idx = resolvedItems.firstIndex(where: { $0.id == item.id }) {
                        resolvedItems[idx].resolution = .matched(selectedPDF)
                    }
                }
            }
            .sheet(isPresented: $showSeriesPicker) {
                SeriesPickerSheet(collections: conversionManager.collections, eventName: eventName) { selectedCollection in
                    buildVolumeSubCollections(into: selectedCollection)
                }
                .environmentObject(conversionManager)
            }
        }
    }
    
    private func confirmSuggestion(item: ResolvedEventItem, with pdf: ConvertedPDF) {
        if let idx = resolvedItems.firstIndex(where: { $0.id == item.id }) {
            resolvedItems[idx].resolution = .matched(pdf)
        }
    }
    
    private func rejectSuggestion(item: ResolvedEventItem) {
        if let idx = resolvedItems.firstIndex(where: { $0.id == item.id }) {
            resolvedItems[idx].resolution = .missing
        }
    }
    
    /// Bulk-accept every suggestion in one tap
    private func acceptAllSuggestions() {
        withAnimation {
            for i in resolvedItems.indices {
                if case .suggested(let pdf) = resolvedItems[i].resolution {
                    resolvedItems[i].resolution = .matched(pdf)
                }
            }
        }
    }
    
    private func buildEventCollection() {
        isProcessing = true
        
        // Extract array of matched PDFs
        var matchedPairs: [(pdf: ConvertedPDF, request: RequestedComicItem)] = []
        for item in resolvedItems {
            if case .matched(let pdf) = item.resolution {
                matchedPairs.append((pdf, item.request))
            }
        }
        
        // Sort by requested sortOrder if provided, else keep parsed sequence
        matchedPairs.sort { a, b in
            let soA = a.request.sortOrder ?? Int.max
            let soB = b.request.sortOrder ?? Int.max
            return soA < soB
        }
        
        let orderedIDs: [UUID] = matchedPairs.map { $0.pdf.id }
        
        let newCollection = PDFCollection(
            id: UUID(),
            name: eventName,
            icon: "list.dash.header.rectangle",
            color: "blue",
            creationDate: Date(),
            explicitCoverFileID: orderedIDs.first,
            manualSortOrder: orderedIDs
        )
        
        // Explicitly assign collection tracking to the matched files in SwiftData visually
        for id in orderedIDs {
            if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == id }) {
                conversionManager.convertedPDFs[idx].collectionId = newCollection.id
            }
        }
        
        conversionManager.collections.append(newCollection)
        conversionManager.saveLibrary()
        
        isProcessing = false
        dismiss()
    }
    
    private func buildOmnibusSequence() {
        let matchedPDFs = resolvedItems.compactMap { item -> ConvertedPDF? in
            if case .matched(let pdf) = item.resolution { return pdf }
            return nil
        }
        guard !matchedPDFs.isEmpty else { return }
        
        // Delegate to background Omnibus processor
        conversionManager.enqueueOmnibus(name: eventName, sourceFiles: matchedPDFs)
        dismiss()
    }
    
    /// Single-series: Creates volume sub-collections within the user-selected parent.
    private func buildVolumeSubCollections(into selectedCollection: PDFCollection?) {
        isProcessing = true
        organizeSeriesVolumes(forSeries: nil, into: selectedCollection)
        conversionManager.saveLibrary()
        isProcessing = false
        dismiss()
    }
    
    /// Multi-series: Automatically processes every distinct series in the CSV.
    private func buildMultiSeriesVolumes() {
        isProcessing = true
        
        for seriesName in distinctSeriesInList {
            let normalizedName = seriesName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            
            let targetCollection: PDFCollection
            if let existing = conversionManager.collections.first(where: {
                $0.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == normalizedName
            }) {
                targetCollection = existing
            } else {
                let newCol = PDFCollection(
                    id: UUID(),
                    name: seriesName,
                    icon: "books.vertical",
                    color: "orange",
                    creationDate: Date()
                )
                conversionManager.collections.append(newCol)
                
                for i in conversionManager.convertedPDFs.indices {
                    if conversionManager.convertedPDFs[i].metadata.series?.lowercased() == normalizedName,
                       conversionManager.convertedPDFs[i].collectionId == nil {
                        conversionManager.convertedPDFs[i].collectionId = newCol.id
                    }
                }
                targetCollection = newCol
            }
            
            organizeSeriesVolumes(forSeries: seriesName, into: targetCollection)
        }
        
        conversionManager.saveLibrary()
        isProcessing = false
        dismiss()
    }
    
    /// Core volume organization logic shared by single and multi-series paths.
    private func organizeSeriesVolumes(forSeries seriesFilter: String?, into parentCollection: PDFCollection?) {
        var volumeBuckets: [String: [(ConvertedPDF, ResolvedEventItem)]] = [:]
        var noVolume: [(ConvertedPDF, ResolvedEventItem)] = []
        
        for item in resolvedItems {
            if case .matched(let pdf) = item.resolution {
                if let filter = seriesFilter {
                    guard item.request.series.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ==
                          filter.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                }
                if let vol = item.request.volume, !vol.isEmpty {
                    volumeBuckets[vol, default: []].append((pdf, item))
                } else {
                    noVolume.append((pdf, item))
                }
            }
        }
        
        let parent: PDFCollection
        if let selected = parentCollection {
            parent = selected
        } else {
            let newParent = PDFCollection(id: UUID(), name: seriesFilter ?? eventName, icon: "books.vertical", color: "orange", creationDate: Date())
            conversionManager.collections.append(newParent)
            parent = newParent
        }
        
        for (pdf, _) in noVolume {
            if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                conversionManager.convertedPDFs[idx].collectionId = parent.id
            }
        }
        
        // ✅ FIXED: Instead of creating messy root-level PDFCollections for every Volume,
        // we just map the PDFs to the parent Series Collection and inject the 'metadata.volume' tag.
        // The `SeriesDetailView` will natively group and visually collapse them into Volume buckets!
        let sortedVolumes = volumeBuckets.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        for vol in sortedVolumes {
            guard let entries = volumeBuckets[vol] else { continue }
            
            for (pdf, _) in entries {
                if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                    conversionManager.convertedPDFs[idx].collectionId = parent.id
                    conversionManager.convertedPDFs[idx].metadata.volume = vol
                }
            }
        }
    }

    private func applyMetadataTags() {
        isProcessing = true
        
        for item in resolvedItems {
            if case .matched(let pdf) = item.resolution {
                // Find and update the underlying PDF model natively in the library
                if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
                    var mutableMeta = conversionManager.convertedPDFs[idx].metadata
                    
                    // Directly inject the CSV Smart List mappings
                    mutableMeta.series = item.request.series
                    mutableMeta.issueNumber = item.request.issueNumber
                    mutableMeta.volume = item.request.volume
                    mutableMeta.tags.append("Smart List Synced")
                    
                    if let ro = item.request.readingOrder { mutableMeta.readingOrder = ro }
                    if let so = item.request.sortOrder { mutableMeta.sortOrder = so }
                    if let lbl = item.request.label { mutableMeta.readingEventLabel = lbl }
                    if let opt = item.request.isOptional { mutableMeta.isOptional = opt }
                    
                    conversionManager.convertedPDFs[idx].metadata = mutableMeta
                }
            }
        }
        
        conversionManager.saveLibrary()
        isProcessing = false
        dismiss()
    }
}

// MARK: - Fast High-Performance Suggestion Cell
struct ResolutionItemSuggestionCell: View {
    let item: ResolvedEventItem
    let pdf: ConvertedPDF
    let onConfirm: () -> Void
    let onDeny: () -> Void
    let onManualMap: () -> Void
    
    @EnvironmentObject var conversionManager: ConversionManager
    @State private var localCover: UIImage? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                // High Performance Rendered Thumbnail
                ZStack {
                    if let directCacheImg = conversionManager.thumbnailCache.object(forKey: pdf.id.uuidString as NSString) {
                        Image(uiImage: directCacheImg)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if let img = localCover {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color(.secondarySystemFill))
                        Image(systemName: "doc.text.fill").foregroundColor(.gray)
                    }
                }
                .frame(width: 54, height: 80)
                .cornerRadius(6)
                .clipped()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Requested: \(item.request.originalText)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Found: \(pdf.name)")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
            }
            
            HStack {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onConfirm()
                }) {
                    Label("Confirm", systemImage: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.borderedProminent).tint(.green)
                
                Button(action: {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    onDeny()
                }) {
                    Label("Deny", systemImage: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.bordered).tint(.red)
                
                Spacer()
                
                Button(action: onManualMap) {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.bordered).tint(.blue)
            }
        }
        .padding(.vertical, 4)
        .task(id: pdf.id) {
            let key = pdf.id.uuidString as NSString
            if let cached = conversionManager.thumbnailCache.object(forKey: key) {
                self.localCover = cached; return
            }
            guard let coverURL = conversionManager.getCoverURL(for: pdf),
                  FileManager.default.fileExists(atPath: coverURL.path) else { return }
            
            // Decoupled background image downsampling
            let generated = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(coverURL as CFURL, sourceOptions) else { return nil }
                let downsampleOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600
                ] as CFDictionary
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else { return nil }
                return UIImage(cgImage: cgImage)
            }.value
            
            if let image = generated {
                conversionManager.thumbnailCache.setObject(image, forKey: key)
                self.localCover = image
            }
        }
    }
}

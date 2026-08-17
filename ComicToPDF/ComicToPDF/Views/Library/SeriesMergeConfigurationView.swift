import SwiftUI
import UniformTypeIdentifiers

@MainActor
class SeriesMergeConfigurationViewModel: ObservableObject {
    @Published var itemsToMerge: [ConvertedPDF]
    @Published var outputName: String
    @Published var mangaMode: Bool = false
    @Published var isProcessing: Bool = false
    
    init(itemsToMerge: [ConvertedPDF], outputName: String) {
        self.itemsToMerge = itemsToMerge
        self.outputName = outputName
    }
}

struct SeriesMergeConfigurationView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    @EnvironmentObject var settingsManager: AppSettingsManager
    
    // Initial configuration
    let seriesFiles: [ConvertedPDF]
    let suggestedName: String?
    
    // State ViewModel
    @StateObject private var viewModel: SeriesMergeConfigurationViewModel
    @State private var draggedItem: ConvertedPDF? = nil
    @State private var remainingSearchQuery = ""
    
    // Range Selection Input
    @State private var rangeStart = ""
    @State private var rangeEnd = ""
    
    // Auto-Suggestion State
    @State private var dismissedNextSuggestionID: UUID? = nil
    
    // Volume Pattern State
    @State private var showPatternSuggestionAlert = false
    @State private var patternSuggestedIssues: [ConvertedPDF] = []
    @State private var patternSuggestedVolumeNumber = 0
    @State private var deleteSourceFilesAfterMerge = false
    
    init(sourceFiles: [ConvertedPDF], suggestedName: String? = nil) {
        self.seriesFiles = sourceFiles
        self.suggestedName = suggestedName
        let initialMerge = sourceFiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let initialName = suggestedName ?? ""
        _viewModel = StateObject(wrappedValue: SeriesMergeConfigurationViewModel(
            itemsToMerge: initialMerge,
            outputName: initialName
        ))
    }
    
    init(seriesFiles: [ConvertedPDF], initialSelection: Set<UUID>, suggestedName: String? = nil) {
        self.seriesFiles = seriesFiles
        self.suggestedName = suggestedName
        let initialMerge = seriesFiles.filter { initialSelection.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let initialName = suggestedName ?? ""
        _viewModel = StateObject(wrappedValue: SeriesMergeConfigurationViewModel(
            itemsToMerge: initialMerge,
            outputName: initialName
        ))
    }
    
    var body: some View {
        NavigationStack {
            VStack {
                if viewModel.isProcessing {
                    ImmersiveConversionOverlay(
                        pdfName: viewModel.outputName.isEmpty ? "Merged Collection" : viewModel.outputName,
                        customMessage: conversionManager.statusMessage ?? "Merging..."
                    )
                } else {
                    Form {
                        Section(header: Text("Output Volume Configuration"), footer: Text("The merged file will automatically be assigned to the current series.")) {
                            TextField("New Volume Name (e.g., Volume 1)", text: $viewModel.outputName)
                            Toggle("Manga Mode (Right-to-Left)", isOn: $viewModel.mangaMode)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Toggle("Pair Front Cover with Page 1", isOn: $settingsManager.conversionSettings.linkCoverAsSpread)
                                Text("Keep OFF for standalone front cover (recommended)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Toggle("Slice Landscape Spreads into 2 Pages", isOn: $settingsManager.conversionSettings.splitSpreads)
                                Text("Keep OFF for native full-bleed landscape on Kindle & Reader")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                            
                            Toggle("Delete original files after merge", isOn: $deleteSourceFilesAfterMerge)
                            
                            Picker("Image Quality", selection: $settingsManager.conversionSettings.compressionQuality) {
                                ForEach(CompressionPreset.allCases) { preset in
                                    Text("\(preset.displayName) (Est: \(estimatedSize(for: preset)))").tag(preset)
                                }
                            }
                            
                            if settingsManager.conversionSettings.compressionQuality == .customTarget {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("Target File Size")
                                            .font(.subheadline)
                                        Spacer()
                                        Text("\(Int(settingsManager.conversionSettings.targetFileSizeMB)) MB")
                                            .font(.subheadline)
                                            .bold()
                                            .foregroundColor(.blue)
                                    }
                                    Slider(value: $settingsManager.conversionSettings.targetFileSizeMB, in: 10...1000, step: 10)
                                }
                                .padding(.vertical, 4)
                            }
                            
                            Picker("Smart File Splitting", selection: $settingsManager.conversionSettings.splitMode) {
                                ForEach(FileSizeSplitMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                        }
                        .listRowBackground(Color.inkSurface.opacity(0.4))
                        
                        Section(header: Text("Size & Compression Preview")) {
                            HStack {
                                Text("Original Combined Size")
                                    .foregroundColor(.inkTextSecondary)
                                Spacer()
                                Text(formatBytes(totalInputSize))
                                    .foregroundColor(.secondary)
                            }
                            
                            HStack {
                                Text("Estimated Merged Size")
                                    .foregroundColor(.inkTextPrimary)
                                Spacer()
                                Text(formatBytes(estimatedOutputSize))
                                    .bold()
                                    .foregroundColor(.inkAmber)
                            }
                            
                            let splitMode = settingsManager.conversionSettings.splitMode
                            if splitMode != .none {
                                HStack {
                                    Text("Splitting Status")
                                        .foregroundColor(.inkTextPrimary)
                                    Spacer()
                                    if willSplit {
                                        Text("⚠️ Splits into \(estimatedParts) files")
                                            .foregroundColor(.inkAmber)
                                            .bold()
                                    } else {
                                        Text("✅ Fits in 1 file")
                                            .foregroundColor(.inkGreen)
                                            .bold()
                                    }
                                }
                            }
                        }
                        .listRowBackground(Color.inkSurface.opacity(0.4))
                        
                        Section(header: HStack {
                            Text("Merge Order")
                            Spacer()
                            if !viewModel.itemsToMerge.isEmpty {
                                Button("Remove All") {
                                    HapticEngine.warning()
                                    withAnimation {
                                        viewModel.itemsToMerge.removeAll()
                                    }
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.red)
                                .buttonStyle(.plain)
                                .textCase(nil)
                            }
                        }, footer: Text(viewModel.itemsToMerge.count < 2 ? "⚠️ Please add at least 2 issues to perform a merge." : "Drag the handles or swipe left to remove. The top file will be the first issue in the merged volume.")) {
                            ForEach(viewModel.itemsToMerge) { pdf in
                                pdfRow(for: pdf)
                                    .onDrop(of: [.text], delegate: ReorderDropDelegate(item: pdf, items: $viewModel.itemsToMerge, draggedItem: $draggedItem))
                            }
                            .onMove(perform: moveItems)
                            .onDelete(perform: removeItems)
                        }
                        .listRowBackground(Color.inkSurface.opacity(0.4))
                        
                        let allRemainingFiles = seriesFiles.filter { file in
                            !viewModel.itemsToMerge.contains(where: { $0.id == file.id })
                        }
                        let remainingFiles = allRemainingFiles.filter { file in
                            if remainingSearchQuery.isEmpty { return true }
                            return matchesSearchQuery(name: file.name, query: remainingSearchQuery)
                        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        
                        if !allRemainingFiles.isEmpty {
                            Section(header: Text("Add Other Issues from Series")) {
                                // 1. Quick Search Bar
                                HStack {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(.secondary)
                                    TextField("Search issue/chapter number...", text: $remainingSearchQuery)
                                        .textFieldStyle(.plain)
                                        .textInputAutocapitalization(.never)
                                        .disableAutocorrection(true)
                                    
                                    if !remainingSearchQuery.isEmpty {
                                        Button {
                                            HapticEngine.light()
                                            remainingSearchQuery = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                
                                // 2. Range-based Selection Row
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.left.and.right")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                    Text("Range:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    TextField("From #", text: $rangeStart)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 55)
                                        .keyboardType(.numberPad)
                                        .multilineTextAlignment(.center)
                                        .font(.caption)
                                    
                                    TextField("To #", text: $rangeEnd)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 55)
                                        .keyboardType(.numberPad)
                                        .multilineTextAlignment(.center)
                                        .font(.caption)
                                    
                                    Spacer()
                                    
                                    Button("Select Range") {
                                        HapticEngine.medium()
                                        selectRangeAction()
                                    }
                                    .font(.caption.bold())
                                    .foregroundColor(.inkBlue)
                                    .buttonStyle(.plain)
                                    .disabled(rangeStart.isEmpty || rangeEnd.isEmpty)
                                }
                                .padding(.vertical, 2)
                                
                                // 3. Next-Issue Auto-suggestion Row
                                if let suggestion = nextSuggestedIssue, let lastFileID = viewModel.itemsToMerge.last?.id {
                                    HStack {
                                        Image(systemName: "lightbulb.fill")
                                            .foregroundColor(.yellow)
                                            .font(.caption)
                                        Text("Next Suggestion: \(suggestion.name)")
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        Button("Add") {
                                            HapticEngine.light()
                                            withAnimation {
                                                viewModel.itemsToMerge.append(suggestion)
                                            }
                                        }
                                        .font(.caption.bold())
                                        .foregroundColor(.inkGreen)
                                        .buttonStyle(.plain)
                                        
                                        Button {
                                            HapticEngine.light()
                                            dismissedNextSuggestionID = lastFileID
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.vertical, 4)
                                    .listRowBackground(Color.yellow.opacity(0.10))
                                }
                                
                                if remainingFiles.isEmpty {
                                    Text("No matching issues found")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .italic()
                                } else {
                                    ForEach(remainingFiles) { pdf in
                                        HStack {
                                            if let uiImage = conversionManager.getThumbnail(for: pdf) {
                                                Image(uiImage: uiImage)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fill)
                                                    .frame(width: 30, height: 45)
                                                    .cornerRadius(4)
                                                    .clipped()
                                            } else {
                                                Rectangle()
                                                    .fill(Color.gray.opacity(0.2))
                                                    .frame(width: 30, height: 45)
                                                    .cornerRadius(4)
                                                    .overlay(Image(systemName: "doc").foregroundColor(.gray))
                                            }
                                            
                                            VStack(alignment: .leading) {
                                                Text(pdf.name)
                                                    .font(.caption)
                                                    .lineLimit(1)
                                                Text(pdf.formattedSize)
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.secondary)
                                            }
                                            
                                            Spacer()
                                            
                                            Button {
                                                HapticEngine.light()
                                                withAnimation {
                                                    viewModel.itemsToMerge.append(pdf)
                                                }
                                            } label: {
                                                Image(systemName: "plus.circle.fill")
                                                    .font(.title3)
                                                    .foregroundColor(.inkGreen)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                            .listRowBackground(Color.inkSurface.opacity(0.4))
                        }
                        
                        Section {
                            Button {
                                startMerge()
                            } label: {
                                HStack {
                                    Spacer()
                                    Text("Convert & Merge")
                                        .bold()
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .disabled(isMergeDisabled)
                            .foregroundColor(isMergeDisabled ? .gray : .white)
                            .listRowBackground(
                                Group {
                                    if isMergeDisabled {
                                        Color.inkSurface.opacity(0.4)
                                    } else {
                                        LinearGradient(colors: [Color.inkBlue, Color.inkViolet.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                                    }
                                }
                            )
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.inkBackground.ignoresSafeArea())
            .navigationTitle("Configure Merge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !viewModel.isProcessing {
                        Button("Cancel") { dismiss() }
                    }
                }
                // Requires EditButton to easily expose drag handles
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !viewModel.isProcessing {
                        EditButton()
                    }
                }
            }
            .alert("Build Volume \(patternSuggestedVolumeNumber)?", isPresented: $showPatternSuggestionAlert) {
                Button("Yes") {
                    HapticEngine.light()
                    withAnimation {
                        viewModel.itemsToMerge = patternSuggestedIssues
                    }
                }
                Button("No", role: .cancel) { }
            } message: {
                Text("We noticed that Volume 1 and Volume 2 each contain \(patternSuggestedIssues.count) issues. Would you like to auto-populate the next \(patternSuggestedIssues.count) issues for Volume \(patternSuggestedVolumeNumber)?")
            }
            .onAppear {
                checkVolumePatterns()
            }
        }
    }
    
    @ViewBuilder
    private func pdfRow(for pdf: ConvertedPDF) -> some View {
        HStack {
            if let uiImage = conversionManager.getThumbnail(for: pdf) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 60)
                    .cornerRadius(4)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 40, height: 60)
                    .cornerRadius(4)
                    .overlay(Image(systemName: "doc").foregroundColor(.gray))
            }
            
            VStack(alignment: .leading) {
                Text(pdf.name)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(pdf.formattedSize)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .onDrag {
                    self.draggedItem = pdf
                    return NSItemProvider(object: pdf.id.uuidString as NSString)
                }
        }
    }
    
    private var isMergeDisabled: Bool {
        viewModel.itemsToMerge.count < 2 || viewModel.outputName.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    private var totalInputSize: Int64 {
        viewModel.itemsToMerge.reduce(0) { $0 + $1.fileSize }
    }
    
    private var totalPageCount: Int {
        let pages = viewModel.itemsToMerge.reduce(0) { $0 + $1.pageCount }
        return pages > 0 ? pages : viewModel.itemsToMerge.count * 25
    }
    
    private func estimatedBytes(for preset: CompressionPreset) -> Int64 {
        let format = settingsManager.conversionSettings.outputFormat
        let pages = totalPageCount
        
        switch preset {
        case .ultra:
            return Int64(Double(totalInputSize) * (format == .epub ? 1.08 : 1.05))
        case .customTarget:
            let targetBytes = Int64(settingsManager.conversionSettings.targetFileSizeMB * 1024 * 1024)
            return min(totalInputSize, targetBytes)
        case .high:
            // High Quality: ~580 KB per page + container scaffolding
            let base = Int64(pages) * 580_000
            return format == .epub ? base + 2_500_000 : base
        case .balanced:
            // Standard: ~420 KB per page + container scaffolding
            let base = Int64(pages) * 420_000
            return format == .epub ? base + 2_500_000 : base
        case .compact:
            // Compact: ~275 KB per page + container scaffolding (calibrated to ~92MB on 325-page omnibus)
            let base = Int64(pages) * 275_000
            return format == .epub ? base + 2_500_000 : base
        }
    }

    private var estimatedOutputSize: Int64 {
        estimatedBytes(for: settingsManager.conversionSettings.compressionQuality)
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        return String(format: "%.1f MB", mb)
    }
    
    private var willSplit: Bool {
        let limit = settingsManager.conversionSettings.splitMode.limit
        return estimatedOutputSize > limit
    }
    
    private var estimatedParts: Int {
        let limit = settingsManager.conversionSettings.splitMode.limit
        guard limit > 0 else { return 1 }
        let parts = Double(estimatedOutputSize) / Double(limit)
        return Int(ceil(parts))
    }
    
    private func estimatedSize(for preset: CompressionPreset) -> String {
        formatBytes(estimatedBytes(for: preset))
    }
    
    private func moveItems(from source: IndexSet, to destination: Int) {
        HapticEngine.light()
        viewModel.itemsToMerge.move(fromOffsets: source, toOffset: destination)
    }
    
    private func removeItems(at offsets: IndexSet) {
        HapticEngine.medium()
        viewModel.itemsToMerge.remove(atOffsets: offsets)
    }
    
    private func startMerge() {
        HapticEngine.medium()
        let files = viewModel.itemsToMerge
        let name = viewModel.outputName.trimmingCharacters(in: .whitespaces)
        let mode = viewModel.mangaMode
        
        viewModel.isProcessing = true
        
        Task {
            // Explicitly extract the Series mapping tag to assign the generated merge automatically
            let seriesTag = files.first?.metadata.series
            
            // Execute the bulk engine and implicitly return the generated data payload
            let mergedBooks = await conversionManager.convertAndMerge(sourceFiles: files, outputName: name, mangaMode: mode, overrideSeries: seriesTag)
            
            await MainActor.run {
                // If the Engine produced an array, safely pop it to the UI (already explicitly added to ConversionManager)
                if let newBook = mergedBooks.first {
                    print("Merged Book generated natively: \(newBook.name)")
                    NotificationCenter.default.post(name: Notification.Name("OpenMergedBook"), object: newBook)
                    
                    if deleteSourceFilesAfterMerge {
                        for file in files {
                            conversionManager.deletePDF(file)
                        }
                    }
                }
                viewModel.isProcessing = false
                dismiss()
            }
        }
    }
    
    // MARK: - Search & Auto-selection Filtering Helpers
    
    private func matchesSearchQuery(name: String, query: String) -> Bool {
        let cleanQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanQuery.isEmpty { return true }
        
        let lowerName = name.lowercased()
        
        // 1. Direct substring match
        if lowerName.contains(cleanQuery) { return true }
        
        // 2. Intelligent number/prefix expansion (e.g. matching "ch 04", "i04", "issue 4", "chapter 4")
        let pattern = #"(ch|chapter|i|issue|vol|volume|v)\s*[-.]?\s*0*(\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(cleanQuery.startIndex..<cleanQuery.endIndex, in: cleanQuery)
            if let match = regex.firstMatch(in: cleanQuery, options: [], range: range) {
                if let numRange = Range(match.range(at: 2), in: cleanQuery) {
                    let numberString = String(cleanQuery[numRange])
                    return matchesNumberInFilename(lowerName: lowerName, numberString: numberString)
                }
            }
        }
        
        // 3. Fallback: if query is just a plain number (e.g. "4"), look for occurrences of that number in the filename boundaries
        if let queryNum = Int(cleanQuery) {
            return matchesNumberInFilename(lowerName: lowerName, numberString: String(queryNum))
        }
        
        return false
    }
    
    private func matchesNumberInFilename(lowerName: String, numberString: String) -> Bool {
        let digitPattern = #"\d+"#
        guard let regex = try? NSRegularExpression(pattern: digitPattern, options: []) else { return false }
        let nsString = lowerName as NSString
        let matches = regex.matches(in: lowerName, options: [], range: NSRange(location: 0, length: nsString.length))
        
        for m in matches {
            let foundDigits = nsString.substring(with: m.range)
            if Int(foundDigits) == Int(numberString) {
                return true
            }
        }
        return false
    }
    
    private func resolvedVolume(for pdf: ConvertedPDF) -> String? {
        if let vol = pdf.metadata.volume, !vol.isEmpty {
            return vol
        }
        let parsed = DeterministicFilenameParser.parse(filename: pdf.name)
        return parsed.volume
    }

    private func parseIssueNumber(from filename: String) -> Int? {
        let parsed = DeterministicFilenameParser.parse(filename: filename)
        if let issueStr = parsed.issueNumber, let issueNum = Int(issueStr) {
            return issueNum
        }
        
        let pattern = #"(?:issue|i|ch|chapter|v|vol|volume|#)?\s*[-.]?\s*0*(\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
            let matches = regex.matches(in: filename, options: [], range: range)
            if let lastMatch = matches.last, lastMatch.numberOfRanges > 1 {
                if let numRange = Range(lastMatch.range(at: 1), in: filename), let num = Int(filename[numRange]) {
                    return num
                }
            }
        }
        return nil
    }
    
    private var nextSuggestedIssue: ConvertedPDF? {
        guard let lastFile = viewModel.itemsToMerge.last else { return nil }
        if let dismissed = dismissedNextSuggestionID, dismissed == lastFile.id { return nil }
        
        guard let lastNum = parseIssueNumber(from: lastFile.name) else { return nil }
        let nextNum = lastNum + 1
        
        let allRemaining = seriesFiles.filter { file in
            !viewModel.itemsToMerge.contains(where: { $0.id == file.id })
        }
        
        return allRemaining.first { file in
            if let num = parseIssueNumber(from: file.name) {
                return num == nextNum
            }
            return false
        }
    }
    
    private func selectRangeAction() {
        guard let start = Int(rangeStart), let end = Int(rangeEnd), start <= end else { return }
        
        let allRemaining = seriesFiles.filter { file in
            !viewModel.itemsToMerge.contains(where: { $0.id == file.id })
        }
        
        let matches = allRemaining.filter { file in
            if let num = parseIssueNumber(from: file.name) {
                return num >= start && num <= end
            }
            return false
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        
        withAnimation {
            viewModel.itemsToMerge.append(contentsOf: matches)
        }
        
        rangeStart = ""
        rangeEnd = ""
    }
    
    private func checkVolumePatterns() {
        // Only run pattern suggestion if itemsToMerge has not been pre-loaded with a custom user selection from detail screen
        guard viewModel.itemsToMerge.count == seriesFiles.count || viewModel.itemsToMerge.isEmpty else { return }
        
        var volumeCounts: [Int: Int] = [:]
        for file in seriesFiles {
            if let volStr = resolvedVolume(for: file), let volNum = Int(volStr) {
                volumeCounts[volNum, default: 0] += 1
            }
        }
        
        guard let count1 = volumeCounts[1], let count2 = volumeCounts[2], count1 == count2, count1 > 0 else {
            return
        }
        
        let patternSize = count1
        let maxVolume = volumeCounts.keys.max() ?? 2
        let nextVolume = maxVolume + 1
        
        if let existingCount = volumeCounts[nextVolume], existingCount > 0 {
            return
        }
        
        let unmergedIssues = seriesFiles.filter { file in
            if let volStr = resolvedVolume(for: file), let volNum = Int(volStr) {
                return volNum >= nextVolume || volNum == 0
            }
            return true
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        
        guard unmergedIssues.count >= patternSize else { return }
        
        let suggested = Array(unmergedIssues.prefix(patternSize))
        self.patternSuggestedIssues = suggested
        self.patternSuggestedVolumeNumber = nextVolume
        self.showPatternSuggestionAlert = true
    }
}

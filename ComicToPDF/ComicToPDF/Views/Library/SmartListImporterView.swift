import SwiftUI
import UniformTypeIdentifiers

struct SmartListImporterView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var resolvedItems: [ResolvedEventItem]? = nil
    enum ListType: String, CaseIterable, Identifiable {
        case crossover = "Crossover Event"
        case volumes = "Series Volumes"
        var id: String { rawValue }
    }
    
    enum OutputFormat: String, CaseIterable, Identifiable {
        case csv = "CSV Table"
        case markdown = "Markdown Table"
        case json = "JSON Array"
        case txt = "Plain Text List"
        var id: String { rawValue }
    }
    
    @State private var listType: ListType = .crossover
    @State private var outputFormat: OutputFormat = .csv
    @State private var errorMessage: String? = nil
    @State private var eventName: String = ""
    @State private var pastedText: String = ""
    @State private var showInventoryCopiedMessage: Bool = false
    @State private var isResolving: Bool = false

    var body: some View {
        Group {
            if let items = resolvedItems {
                EventResolutionSheet(eventName: eventName, resolvedItems: items)
            } else {
                NavigationStack {
                    ScrollView {
                        VStack(spacing: 28) {
                            // ── HEADER SECTION ───────────────────────────────────────
                            VStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.inkViolet.opacity(0.12))
                                        .frame(width: 90, height: 90)
                                    
                                    Image(systemName: "sparkles.rectangle.stack")
                                        .font(.system(size: 44, weight: .semibold))
                                        .foregroundStyle(
                                            LinearGradient(
                                                colors: [.inkViolet, .inkBlue],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                }
                                .padding(.top, 8)
                                
                                Text("Smart Reading Lists")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.inkTextPrimary)
                                
                                Text("Organize cross-series crossover events or slice series runs into volumes. Let Inksync Pro parse XML, CSV, JSON, or plain text outputs from AI models.")
                                    .font(.subheadline)
                                    .foregroundColor(.inkTextSecondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                                    .lineSpacing(4)
                            }
                            .padding(.top, 10)
                            
                            // ── LIST TYPE SEGMENTED CONTROL ──────────────────────────
                            VStack(spacing: 8) {
                                Picker("List Type", selection: $listType) {
                                    ForEach(ListType.allCases) { type in
                                        Text(type.rawValue).tag(type)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .onChange(of: listType) {
                                    HapticEngine.selection()
                                }
                            }
                            .padding(.horizontal, 24)
                            
                            // ── EVENT CONFIGURATION CARD ─────────────────────────────
                            VStack(spacing: 20) {
                                if listType == .crossover {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Event / Crossover Name")
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .foregroundColor(.inkViolet)
                                            .textCase(.uppercase)
                                        
                                        TextField("e.g. Civil War, Dark Web, Spider-Verse", text: $eventName)
                                            .font(.body)
                                            .foregroundColor(.inkTextPrimary)
                                            .padding(.vertical, 4)
                                        
                                        Divider()
                                            .background(Color.inkBorderSubtle)
                                        
                                        Text("The name for the playlist folder and generated metadata.")
                                            .font(.caption2)
                                            .foregroundColor(.inkTextSecondary)
                                    }
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                                
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("AI Prompt Target Format")
                                                .font(.caption)
                                                .fontWeight(.bold)
                                                .foregroundColor(.inkViolet)
                                                .textCase(.uppercase)
                                            
                                            Text("The layout structure requested from the AI.")
                                                .font(.caption2)
                                                .foregroundColor(.inkTextSecondary)
                                        }
                                        Spacer()
                                        Picker("Format", selection: $outputFormat) {
                                            ForEach(OutputFormat.allCases) { format in
                                                Text(format.rawValue).tag(format)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .tint(.inkViolet)
                                        .onChange(of: outputFormat) {
                                            HapticEngine.selection()
                                        }
                                    }
                                }
                            }
                            .padding(20)
                            .background(Color.inkSurface)
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.inkBorderSubtle, lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 3)
                            .padding(.horizontal, 24)
                            
                            // ── AI GENERATION & FILE ACTIONS CARD ────────────────────
                            VStack(spacing: 20) {
                                // Subcard 1: AI Clipboard Copy
                                Button(action: {
                                    copyLibraryInventoryToClipboard()
                                }) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Label("Copy Library Inventory & AI Prompt", systemImage: "doc.on.clipboard.fill")
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundColor(.inkViolet)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundColor(.inkViolet)
                                        }
                                        
                                        Text("Generates a comprehensive system prompt enclosing your library inventory. Paste this directly into ChatGPT, Claude, Gemini, or other models to generate the list.")
                                            .font(.caption)
                                            .foregroundColor(.inkTextSecondary)
                                            .lineSpacing(3)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .padding(16)
                                    .background(Color.inkViolet.opacity(0.08))
                                    .cornerRadius(12)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.inkViolet.opacity(0.2), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                                
                                // Subcard 2: Document Picker Import
                                Button(action: {
                                    HapticEngine.light()
                                    ImportCoordinator.present(type: .smartList) { urls in
                                        if let url = urls.first {
                                            handleSmartListURL(url)
                                        }
                                    }
                                }) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Label("Import Smart List Document File", systemImage: "folder.badge.plus")
                                                .font(.system(size: 15, weight: .bold))
                                                .foregroundColor(.inkBlue)
                                            Spacer()
                                            Image(systemName: "arrow.up.doc")
                                                .font(.caption)
                                                .foregroundColor(.inkBlue)
                                        }
                                        
                                        Text("Directly load a ComicRack .cbl file, standard .csv sheet, raw .txt list, or structured JSON file from the iOS Files app.")
                                            .font(.caption)
                                            .foregroundColor(.inkTextSecondary)
                                            .lineSpacing(3)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .padding(16)
                                    .background(Color.inkBlue.opacity(0.08))
                                    .cornerRadius(12)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.inkBlue.opacity(0.2), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(20)
                            .background(Color.inkSurface)
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.inkBorderSubtle, lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 3)
                            .padding(.horizontal, 24)
                            
                            // ── PASTED INPUT & RESOLUTION SECTION ────────────────────
                            VStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Label("Paste Generated AI Response", systemImage: "doc.text.magnifyingglass")
                                            .font(.subheadline)
                                            .fontWeight(.bold)
                                            .foregroundColor(.inkTextPrimary)
                                        Spacer()
                                        
                                        Button {
                                            pastedText = "ReadingOrder,SortOrder,Series,Issue,Volume,Label,Optional\nCivil War,1,Amazing Spider-Man,529,,Prelude,false\nCivil War,2,New Avengers,21,,Prelude,true\nCivil War,3,Civil War,1,,Main,false"
                                            HapticEngine.light()
                                        } label: {
                                            Text("Use Template")
                                                .font(.caption)
                                                .fontWeight(.bold)
                                                .foregroundColor(.inkViolet)
                                        }
                                    }
                                    
                                    ZStack(alignment: .topLeading) {
                                        TextEditor(text: $pastedText)
                                            .font(.system(size: 13, design: .monospaced))
                                            .foregroundColor(.inkTextPrimary)
                                            .autocorrectionDisabled(true)
                                            .textInputAutocapitalization(.never)
                                            .scrollContentBackground(.hidden)
                                            .frame(minHeight: 140, maxHeight: 240)
                                            .padding(12)
                                            .background(Color.inkSurfaceRaised)
                                            .cornerRadius(12)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke(Color.inkBorderSubtle, lineWidth: 1)
                                            )
                                        
                                        if pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text("Paste the CSV, Markdown, JSON, or Plain Text list here...")
                                                .font(.system(size: 13))
                                                .foregroundColor(.inkTextSecondary)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 20)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                }
                                
                                if !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Button {
                                        HapticEngine.success()
                                        handlePastedText()
                                    } label: {
                                        HStack {
                                            Image(systemName: "play.fill")
                                            Text("Parse & Resolve Pasted List")
                                                .fontWeight(.bold)
                                        }
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .padding(.vertical, 14)
                                        .frame(maxWidth: .infinity)
                                        .background(
                                            LinearGradient(
                                                colors: [.inkGreen, Color.inkGreen.opacity(0.85)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .cornerRadius(12)
                                        .shadow(color: Color.inkGreen.opacity(0.3), radius: 8, x: 0, y: 4)
                                    }
                                    .buttonStyle(.plain)
                                    .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .padding(20)
                            .background(Color.inkSurface)
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.inkBorderSubtle, lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 3)
                            .padding(.horizontal, 24)
                            
                            if let err = errorMessage {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.inkRed)
                                    Text(err)
                                        .font(.caption)
                                        .foregroundColor(.inkRed)
                                        .multilineTextAlignment(.leading)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .background(Color.inkRed.opacity(0.08))
                                .cornerRadius(8)
                                .padding(.horizontal, 24)
                                .transition(.opacity)
                            }
                            
                            // ── FORMAT INFO SECTION ──────────────────────────────────
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Supported AI Formats")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.inkTextSecondary)
                                    .textCase(.uppercase)
                                
                                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                                    GridRow {
                                        Label("CSV Table", systemImage: "tablecells.fill")
                                            .foregroundColor(.inkViolet)
                                        Text("Standard columns split by commas.")
                                            .font(.caption)
                                            .foregroundColor(.inkTextSecondary)
                                    }
                                    GridRow {
                                        Label("Markdown", systemImage: "doc.text.fill")
                                            .foregroundColor(.inkViolet)
                                        Text("Piped table syntax generated by LLMs.")
                                            .font(.caption)
                                            .foregroundColor(.inkTextSecondary)
                                    }
                                    GridRow {
                                        Label("JSON Array", systemImage: "curlybraces")
                                            .foregroundColor(.inkViolet)
                                        Text("Structured dictionary matching Inksync schema.")
                                            .font(.caption)
                                            .foregroundColor(.inkTextSecondary)
                                    }
                                    GridRow {
                                        Label("Plain Text", systemImage: "doc.plaintext.fill")
                                            .foregroundColor(.inkViolet)
                                        Text("Key-value lines (e.g. Series: X, Issue: Y).")
                                            .font(.caption)
                                            .foregroundColor(.inkTextSecondary)
                                    }
                                }
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.inkSurface.opacity(0.5))
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.inkBorderSubtle, lineWidth: 1)
                            )
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                        }
                    }
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .background(Color.inkBackground)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                                .foregroundColor(.inkTextSecondary)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showInventoryCopiedMessage {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.inkGreen)
                    Text("Prompt & Inventory Copied")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(Color.inkBackground.opacity(0.95))
                        .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
                )
                .padding(.bottom, 40)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if isResolving {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .inkViolet))
                            .scaleEffect(1.5)
                        
                        Text("Resolving Library Matches...")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(28)
                    .background(Color.inkSurface)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
                }
                .transition(.opacity)
            }
        }
        .forceProMotion()
    }
        
    private func handleSmartListURL(_ selectedFile: URL) {
        do {
            // Set default event name to filename if default wasn't changed
            if eventName == "Imported Event" {
                eventName = selectedFile.deletingPathExtension().lastPathComponent
            }
            
            // Handle security scoping flexibly for local copies
            let isAccessing = selectedFile.startAccessingSecurityScopedResource()
            defer { if isAccessing { selectedFile.stopAccessingSecurityScopedResource() } }
            
            let ext = selectedFile.pathExtension.lowercased()
            let cleanFilename = selectedFile.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
            
            var requests: [RequestedComicItem] = []
            
            if ext == "cbl" || ext == "xml" {
                requests = try SmartListImporter.shared.parseCBL(from: selectedFile)
            } else {
                // parseCSVList will automatically fallback to parseTextList if columns.count == 1
                requests = try SmartListImporter.shared.parseCSVList(from: selectedFile, defaultSeriesName: cleanFilename)
            }
            
            if requests.isEmpty {
                errorMessage = "No recognizable comic list entries found in the document."
                return
            }
            
            // Perform resolution against local library asynchronously
            isResolving = true
            let customAliases = AppSettingsManager.shared.conversionSettings.customAliases
            let pdfs = conversionManager.convertedPDFs
            
            Task {
                let resolutions = await SmartListImporter.shared.resolveList(requests, against: pdfs, customAliases: customAliases)
                
                await MainActor.run {
                    self.isResolving = false
                    
                    let matchedPDFs = resolutions.compactMap { item -> ConvertedPDF? in
                        if case .matched(let pdf) = item.resolution { return pdf }
                        if case .suggested(let pdf) = item.resolution { return pdf }
                        return nil
                    }
                    
                    // ── Smart Series Affinity Detection ─────────────────────────────────────
                    if let explicitEventName = requests.first(where: { $0.readingOrder != nil })?.readingOrder, !explicitEventName.isEmpty {
                        eventName = explicitEventName
                    } else if !matchedPDFs.isEmpty {
                        var collectionVotes: [UUID: (count: Int, name: String)] = [:]
                        for pdf in matchedPDFs {
                            if let colId = pdf.collectionId,
                               let col = conversionManager.collections.first(where: { $0.id == colId }) {
                                let existing = collectionVotes[colId] ?? (count: 0, name: col.name)
                                collectionVotes[colId] = (count: existing.count + 1, name: col.name)
                            }
                        }
                        
                        if let dominant = collectionVotes.max(by: { $0.value.count < $1.value.count }) {
                            let affinityRatio = Double(dominant.value.count) / Double(matchedPDFs.count)
                            if affinityRatio >= 0.7 {
                                eventName = dominant.value.name
                            }
                        }
                    }
                    
                    withAnimation {
                        self.resolvedItems = resolutions
                    }
                }
            }
            
        } catch {
            errorMessage = error.localizedDescription
            isResolving = false
        }
    }
    
    private func handlePastedText() {
        let clean = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return }
        
        let safeName = eventName.isEmpty || eventName == "Imported Event" ? "Pasted Event" : eventName
        self.eventName = safeName // make sure UI reflects this
        
        let requests = SmartListImporter.shared.parsePastedText(clean, defaultSeriesName: safeName)
        
        if requests.isEmpty {
            errorMessage = "No recognizable comic list entries found in the pasted content."
            return
        }
        
        isResolving = true
        let customAliases = AppSettingsManager.shared.conversionSettings.customAliases
        let pdfs = conversionManager.convertedPDFs
        
        Task {
            let resolutions = await SmartListImporter.shared.resolveList(requests, against: pdfs, customAliases: customAliases)
            
            await MainActor.run {
                self.isResolving = false
                
                let matchedPDFs = resolutions.compactMap { item -> ConvertedPDF? in
                    if case .matched(let pdf) = item.resolution { return pdf }
                    if case .suggested(let pdf) = item.resolution { return pdf }
                    return nil
                }
                
                // ── Smart Series Affinity Detection ─────────────────────────────────────
                if let explicitEventName = requests.first(where: { $0.readingOrder != nil })?.readingOrder, !explicitEventName.isEmpty {
                    eventName = explicitEventName
                } else if !matchedPDFs.isEmpty {
                    var collectionVotes: [UUID: (count: Int, name: String)] = [:]
                    for pdf in matchedPDFs {
                        if let colId = pdf.collectionId,
                           let col = conversionManager.collections.first(where: { $0.id == colId }) {
                            let existing = collectionVotes[colId] ?? (count: 0, name: col.name)
                            collectionVotes[colId] = (count: existing.count + 1, name: col.name)
                        }
                    }
                    
                    if let dominant = collectionVotes.max(by: { $0.value.count < $1.value.count }) {
                        let affinityRatio = Double(dominant.value.count) / Double(matchedPDFs.count)
                        if affinityRatio >= 0.7 {
                            eventName = dominant.value.name
                        }
                    }
                }
                
                withAnimation {
                    self.resolvedItems = resolutions
                }
            }
        }
    }
    
    private func copyLibraryInventoryToClipboard() {
        let pdfs = conversionManager.convertedPDFs
        
        let inventoryText: String
        if pdfs.isEmpty {
            inventoryText = "(No items in library. Import files first!)"
        } else {
            var seriesGroups: [String: [String]] = [:]
            for pdf in pdfs {
                let seriesName = pdf.metadata.series ?? pdf.name.replacingOccurrences(of: ".\(pdf.url.pathExtension)", with: "")
                let issue = pdf.metadata.issueNumber ?? "1"
                seriesGroups[seriesName, default: []].append(issue)
            }
            
            var inventoryLines: [String] = []
            for (series, issues) in seriesGroups.sorted(by: { $0.key < $1.key }) {
                let sortedIssues = issues.sorted { a, b in
                    if let na = Int(a), let nb = Int(b) {
                        return na < nb
                    }
                    return a < b
                }
                let uniqueIssues = Array(NSOrderedSet(array: sortedIssues)) as? [String] ?? sortedIssues
                inventoryLines.append("- \(series) (Issues: \(uniqueIssues.joined(separator: ", ")))")
            }
            inventoryText = inventoryLines.joined(separator: "\n")
        }
        
        let crossoverInstructions: String
        let volumesInstructions: String
        
        switch outputFormat {
        case .csv:
            crossoverInstructions = """
            Output format: A clean CSV table with the exact header below. Do not include markdown code block syntax (like ```csv), commentary, explanation, or conversational intro/outro text. Start directly with the header row.
            
            --- TARGET SCHEMA ---
            Series,Issue,Volume,Label,Optional
            
            --- FEW-SHOT EXAMPLE OUTPUT ---
            Series,Issue,Volume,Label,Optional
            Dark Web: X-Men,1-3,Vol 1,Main,false
            Dragon Ball,1-7,Vol 1,Collection,false
            """
            
            volumesInstructions = """
            Output format: A clean CSV table with the exact header below. Do not include markdown code block syntax (like ```csv), commentary, explanation, or conversational intro/outro text. Start directly with the header row.
            
            --- TARGET SCHEMA ---
            Series,Issue,Volume,Label,Optional
            
            --- FEW-SHOT EXAMPLE OUTPUT ---
            Series,Issue,Volume,Label,Optional
            Initial D,1-10,Vol 01,Collection,false
            Initial D,11-20,Vol 02,Collection,false
            Invincible,1-47,Compendium 1,Collection,false
            """
            
        case .markdown:
            crossoverInstructions = """
            Output format: A clean Markdown table with the exact columns below. Do not include commentary, explanation, or conversational intro/outro text. Start directly with the table.
            
            --- TARGET SCHEMA ---
            | Series | Issue | Volume | Label | Optional |
            | :--- | :--- | :--- | :--- | :--- |
            
            --- FEW-SHOT EXAMPLE OUTPUT ---
            | Series | Issue | Volume | Label | Optional |
            | :--- | :--- | :--- | :--- | :--- |
            | Dark Web: X-Men | 1-3 | Vol 1 | Main | false |
            | Dragon Ball | 1-7 | Vol 1 | Collection | false |
            """
            
            volumesInstructions = """
            Output format: A clean Markdown table with the exact columns below. Do not include commentary, explanation, or conversational intro/outro text. Start directly with the table.
            
            --- TARGET SCHEMA ---
            | Series | Issue | Volume | Label | Optional |
            | :--- | :--- | :--- | :--- | :--- |
            
            --- FEW-SHOT EXAMPLE OUTPUT ---
            | Series | Issue | Volume | Label | Optional |
            | :--- | :--- | :--- | :--- | :--- |
            | Initial D | 1-10 | Vol 01 | Collection | false |
            | Initial D | 11-20 | Vol 02 | Collection | false |
            | Invincible | 1-47 | Compendium 1 | Collection | false |
            """
            
        case .json:
            crossoverInstructions = """
            Output format: A clean JSON array of objects with the exact keys below. Do not include markdown code block syntax (like ```json), commentary, explanation, or conversational intro/outro text. Start directly with the opening bracket `[`.
            
            --- TARGET SCHEMA KEYS ---
            - Series (String)
            - Issue (String or Int)
            - Volume (String)
            - Label (String)
            - Optional (Boolean)
            
            --- FEW-SHOT EXAMPLE OUTPUT ---
            [
              {
                "Series": "Dark Web: X-Men",
                "Issue": "1-3",
                "Volume": "Vol 1",
                "Label": "Main",
                "Optional": false
              },
              {
                "Series": "Dragon Ball",
                "Issue": "1-7",
                "Volume": "Vol 1",
                "Label": "Collection",
                "Optional": false
              }
            ]
            """
            
            volumesInstructions = """
            Output format: A clean JSON array of objects with the exact keys below. Do not include markdown code block syntax (like ```json), commentary, explanation, or conversational intro/outro text. Start directly with the opening bracket `[`.
            
            --- TARGET SCHEMA KEYS ---
            - Series (String)
            - Issue (String or Int)
            - Volume (String)
            - Label (String)
            - Optional (Boolean)
            
            --- FEW-SHOT EXAMPLE OUTPUT ---
            [
              {
                "Series": "Initial D",
                "Issue": "1-10",
                "Volume": "Vol 01",
                "Label": "Collection",
                "Optional": false
              },
              {
                "Series": "Initial D",
                "Issue": "11-20",
                "Volume": "Vol 02",
                "Label": "Collection",
                "Optional": false
              }
            ]
            """
            
        case .txt:
            crossoverInstructions = """
            Output format: A clean plain text list of key-value lines with the exact format below. Do not include commentary, explanation, or conversational intro/outro text.
            
            --- TARGET FORMAT ---
            - Series: [Series Name], Issue: [Issue Number], Volume: [Volume Name], Label: [Label Name], Optional: [Boolean]
            
            --- FEW-SHOT EXAMPLE OUTPUT ---
            - Series: Dark Web: X-Men, Issue: 1-3, Volume: Vol 1, Label: Main, Optional: false
            - Series: Dragon Ball, Issue: 1-7, Volume: Vol 1, Label: Collection, Optional: false
            """
            
            volumesInstructions = """
            Output format: A clean plain text list of key-value lines with the exact format below. Do not include commentary, explanation, or conversational intro/outro text.
            
            --- TARGET FORMAT ---
            - Series: [Series Name], Issue: [Issue Number], Volume: [Volume Name], Label: [Label Name], Optional: [Boolean]
            
            --- FEW-SHOT EXAMPLE OUTPUT ---
            - Series: Initial D, Issue: 1-10, Volume: Vol 01, Label: Collection, Optional: false
            - Series: Initial D, Issue: 11-20, Volume: Vol 02, Label: Collection, Optional: false
            """
        }
        
        let aiPrompt: String
        switch listType {
        case .crossover:
            let targetEvent = eventName.isEmpty || eventName == "Imported Event" ? "Dark Web (or suggest the best fit crossover for these issues)" : eventName
            aiPrompt = """
            You are an expert comic book reading order organizer for Inksync Pro.
            The user wants to generate a custom, properly-sequenced reading order or smart list for a specific crossover event or series run.
            
            Using your extensive real-world knowledge of official comic book publishing histories, event checklists, and reading guides:
            1. Generate the complete, official real-world reading order for the requested event/crossover.
            2. Cross-reference the user's library inventory below to match series names correctly, but include ALL issues in the official order (even if they are missing from the user's inventory) so the user can see what they are missing.
            
            \(crossoverInstructions)
            
            --- CURRENT USER REQUEST ---
            Please create a reading order event for: "\(targetEvent)"
            
            --- USER LIBRARY INVENTORY ---
            \(inventoryText)
            """
            
        case .volumes:
            aiPrompt = """
            You are an expert comic book library organizer for Inksync Pro.
            The user wants to group the issues in their library into logical volumes, compendiums, or collections.
            
            Using official real-world publishing chronology, trade paperback (TPB) structures, and volume releases:
            1. Group the issues in the library below into logical, official chronological Volumes or Collections based on official publishing standards (e.g. Vol 1, Vol 2, Compendium 1).
            2. Ensure volume numbers and issue spans match real-world publications.
            
            \(volumesInstructions)
            
            --- CURRENT USER REQUEST ---
            Please organize the following library series into volume collections. Group issues chronologically by volume.
            
            --- USER LIBRARY INVENTORY ---
            \(inventoryText)
            """
        }
        
        UIPasteboard.general.string = aiPrompt
        HapticEngine.success()
        
        withAnimation {
            showInventoryCopiedMessage = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation {
                showInventoryCopiedMessage = false
            }
        }
    }
}

// MARK: - ProMotion High Frame Rate Lock

struct ProMotionFrameRateModifier: ViewModifier {
    @State private var displayLink: CADisplayLink?

    func body(content: Content) -> some View {
        content
            .onAppear {
                let link = CADisplayLink(target: FrameRateTracker(), selector: #selector(FrameRateTracker.dummy))
                if #available(iOS 15.0, *) {
                    link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
                }
                link.add(to: .main, forMode: .common)
                self.displayLink = link
            }
            .onDisappear {
                displayLink?.invalidate()
                displayLink = nil
            }
    }

    private class FrameRateTracker: NSObject {
        @objc func dummy() {}
    }
}

extension View {
    func forceProMotion() -> some View {
        self.modifier(ProMotionFrameRateModifier())
    }
}



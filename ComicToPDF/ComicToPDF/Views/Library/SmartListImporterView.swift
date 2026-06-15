import SwiftUI
import UniformTypeIdentifiers

struct SmartListImporterView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var resolvedItems: [ResolvedEventItem]? = nil
    @State private var errorMessage: String? = nil
    @State private var eventName: String = "Imported Event"
    @State private var pastedText: String = ""
    @State private var showInventoryCopiedMessage: Bool = false



    var body: some View {
            Group {
                if let items = resolvedItems {
                    EventResolutionSheet(eventName: eventName, resolvedItems: items)
                } else {
                    NavigationStack {
                        ScrollView {
                            VStack(spacing: 24) {
                            Group {
                                Image(systemName: "list.star")
                                    .font(.system(size: 60))
                                    .foregroundColor(.purple)
                                
                                Text("Smart Reading Lists")
                                    .font(.title).bold()
                                
                                Text("Import a .cbl (Comic Book List) or a basic .CSV text list of issues to automatically generate a properly-sequenced custom reading event from your local library.")
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(Color(.secondaryLabel))
                                    .padding(.horizontal)
                            }
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Supported Formats:")
                                    .font(.headline)
                                Label("ComicRack .cbl Files", systemImage: "xmark.curlybrace")
                                Label("Comma Separated Values (.csv)", systemImage: "tablecells")
                                Label("Plain Text Lists (.txt)", systemImage: "doc.plaintext")
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                            
                            HStack(spacing: 16) {
                                Button(action: {
                                    ImportCoordinator.present(type: .smartList) { urls in
                                        if let url = urls.first {
                                            handleSmartListURL(url)
                                        }
                                    }
                                }) {
                                    Label("Import CSV/CBL File", systemImage: "tablecells")
                                        .font(.headline)
                                        .padding(.horizontal, 16).padding(.vertical, 12)
                                        .frame(maxWidth: .infinity)
                                        .background(Color(.systemBlue).opacity(0.15))
                                        .foregroundColor(Color(.systemBlue))
                                        .cornerRadius(12)
                                }
                                
                                Button(action: {
                                    ImportCoordinator.present(type: .smartList) { urls in
                                        if let url = urls.first {
                                            handleSmartListURL(url)
                                        }
                                    }
                                }) {
                                    Label("Import Text File", systemImage: "doc.plaintext")
                                        .font(.headline)
                                        .padding(.horizontal, 16).padding(.vertical, 12)
                                        .frame(maxWidth: .infinity)
                                        .background(Color(.systemGreen).opacity(0.15))
                                        .foregroundColor(Color(.systemGreen))
                                        .cornerRadius(12)
                                }
                            }
                            .padding(.horizontal, 40)
                            
                            TextField("Event Name", text: $eventName)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .padding(.horizontal, 40)
                            
                            
                            Text("Or paste your list directly:")
                                .font(.subheadline)
                                .foregroundColor(Color(.secondaryLabel))
                            
                            TextEditor(text: $pastedText)
                                .font(.system(size: 13, design: .monospaced))
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.never)
                                .frame(minHeight: 150, maxHeight: 350)
                                .padding(8)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(8)
                                .padding(.horizontal, 40)
                            
                            Button {
                                pastedText = "ReadingOrder,SortOrder,Series,Issue,Volume,Label,Optional\nCivil War,1,Amazing Spider-Man,529,,Prelude,false\nCivil War,2,New Avengers,21,,Prelude,true\nCivil War,3,Civil War,1,,Main,false"
                            } label: {
                                Label("Paste Example Reading Order Template", systemImage: "doc.on.clipboard")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                            
                            Button {
                                copyLibraryInventoryToClipboard()
                            } label: {
                                Label("Copy Library Inventory for AI Generation", systemImage: "doc.on.clipboard.fill")
                                    .font(.caption)
                                    .foregroundColor(.purple)
                            }
                            .padding(.top, 4)
                            
                            if showInventoryCopiedMessage {
                                Text("AI Prompt & Library Inventory copied to clipboard!")
                                    .font(.caption2)
                                    .foregroundColor(.purple)
                                    .transition(.opacity)
                            }
                            
                            if !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Button {
                                    handlePastedText()
                                } label: {
                                    Label("Parse Pasted List", systemImage: "doc.text.magnifyingglass")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .padding()
                                        .frame(maxWidth: .infinity)
                                        .background(Color.green)
                                        .cornerRadius(12)
                                        .padding(.horizontal, 40)
                                }
                            }
                            
                            if let err = errorMessage {
                                Text(err)
                                    .foregroundColor(.red)
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                    .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { dismiss() }
                            }
                        }
                    }
                }
            }
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
            
            // Perform resolution against local library
            let resolutions = SmartListImporter.shared.resolveList(requests, against: conversionManager.convertedPDFs)
            
            let matchedPDFs = resolutions.compactMap { item -> ConvertedPDF? in
                if case .matched(let pdf) = item.resolution { return pdf }
                if case .suggested(let pdf) = item.resolution { return pdf }
                return nil
            }
            
            // ── Smart Series Affinity Detection ─────────────────────────────────────
            // If the parser found an explicit ReadingOrder name, use it
            if let explicitEventName = requests.first(where: { $0.readingOrder != nil })?.readingOrder, !explicitEventName.isEmpty {
                eventName = explicitEventName
            }
            // Analyze matched items to detect if the list references a single existing
            // series collection. If 70%+ of matched files share one collection, this
            // is a "series volume breakdown" not a crossover event — auto-bind to it.
            else if !matchedPDFs.isEmpty {
                var collectionVotes: [UUID: (count: Int, name: String)] = [:]
                for pdf in matchedPDFs {
                    if let colId = pdf.collectionId,
                       let col = conversionManager.collections.first(where: { $0.id == colId }) {
                        let existing = collectionVotes[colId] ?? (count: 0, name: col.name)
                        collectionVotes[colId] = (count: existing.count + 1, name: col.name)
                    }
                }
                
                // Find dominant collection
                if let dominant = collectionVotes.max(by: { $0.value.count < $1.value.count }) {
                    let affinityRatio = Double(dominant.value.count) / Double(matchedPDFs.count)
                    if affinityRatio >= 0.7 {
                        // This list references an existing series — bind to it
                        eventName = dominant.value.name
                    }
                }
            }
            
            withAnimation {
                self.resolvedItems = resolutions
            }
            
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func handlePastedText() {
        let clean = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return }
        
        let safeName = eventName.isEmpty || eventName == "Imported Event" ? "Pasted Event" : eventName
        self.eventName = safeName // make sure UI reflects this
        
        do {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).csv")
            try clean.write(to: tempURL, atomically: true, encoding: .utf8)
            handleSmartListURL(tempURL)
        } catch {
            errorMessage = "Failed to process text."
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
        
        let aiPrompt = """
        You are an expert comic book reading order organizer for Inksync Pro.
        The user wants to generate a custom, properly-sequenced reading order or smart list for a specific crossover event or series run.
        
        Your task is to organize a reading list using ONLY the series/issues actually present in the user's library inventory below.
        
        Output format: A clean CSV table with the exact header below. Do not include markdown code block syntax (like ```csv), commentary, explanation, or conversational intro/outro text. Start directly with the header row.
        
        --- TARGET SCHEMA ---
        Series,Issue,Volume,Label,Optional
        
        --- FIELD DEFINITIONS ---
        - Series (String): Name of the comic book series (must match or closely relate to a series in the inventory).
        - Issue (String or Int): The specific issue number (e.g. 5) or range of issues (e.g. 1-7).
        - Volume (String, optional): The collection volume name if matched as a volume or compendium file (e.g. 'Vol 1' or 'Compendium 1').
        - Label (String): Category of the comic in the event. Must be one of: 'Main', 'Tie-In', 'Prelude', or 'Collection'.
        - Optional (Boolean): 'true' if the issue can be skipped, 'false' if it's main reading.
        
        --- FEW-SHOT EXAMPLE OUTPUT ---
        Series,Issue,Volume,Label,Optional
        Dark Web: X-Men,1-3,Vol 1,Main,false
        Dragon Ball,1-7,Vol 1,Collection,false
        TMNT: The Last Ronin,1-5,Vol 1,Collection,false
        
        --- CURRENT USER REQUEST ---
        Please create a reading order event for: [INSERT YOUR DESIRED EVENT OR RUN HERE, E.g. "Dark Web" or "Invincible Compendiums"]
        
        --- USER LIBRARY INVENTORY ---
        \(inventoryText)
        """
        
        UIPasteboard.general.string = aiPrompt
        
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



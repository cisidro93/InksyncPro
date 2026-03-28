import SwiftUI

struct EventResolutionSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var conversionManager: ConversionManager
    
    let eventName: String
    @State var resolvedItems: [ResolvedEventItem]
    
    @State private var showingConfirmation = false
    @State private var isProcessing = false
    
    var autoMatched: [ResolvedEventItem] { resolvedItems.filter { if case .matched = $0.resolution { return true }; return false } }
    var suggested: [ResolvedEventItem] { resolvedItems.filter { if case .suggested = $0.resolution { return true }; return false } }
    var missing: [ResolvedEventItem] { resolvedItems.filter { if case .missing = $0.resolution { return true }; return false } }
    
    var omnibusTotalMB: Int {
        let bytes = resolvedItems.compactMap { item -> Int? in
            if case .matched(let p) = item.resolution { return p.sizeInBytes }
            return nil
        }.reduce(0, +)
        return bytes / 1024 / 1024
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Total Required: \(resolvedItems.count)").font(.footnote).foregroundColor(.secondary)
                            HStack(spacing: 12) {
                                Label("\(autoMatched.count) Matched", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                                Label("\(suggested.count) Review", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
                                Label("\(missing.count) Missing", systemImage: "xmark.circle.fill").foregroundColor(.red)
                            }
                            .font(.caption)
                            .padding(.top, 4)
                        }
                    }
                }
                
                if !suggested.isEmpty {
                    Section(header: Text("Action Required (Suggestions)").foregroundColor(.orange)) {
                        ForEach(suggested.indices, id: \.self) { index in
                            let item = suggested[index]
                            if case .suggested(let pdf) = item.resolution {
                                VStack(alignment: .leading) {
                                    Text("Requested: \(item.request.originalText)")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Text("Found: \(pdf.name)")
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    
                                    HStack {
                                        Button(action: {
                                            // Explicit confirm -> move to matched
                                            confirmSuggestion(item: item, with: pdf)
                                        }) {
                                            Label("Confirm Match", systemImage: "checkmark")
                                        }.buttonStyle(.borderedProminent).tint(.green)
                                        
                                        Button(action: {
                                            // Reject -> move to missing
                                            rejectSuggestion(item: item)
                                        }) {
                                            Label("Deny", systemImage: "xmark")
                                        }.buttonStyle(.bordered).tint(.red)
                                    }
                                    .padding(.top, 4)
                                }
                            }
                        }
                    }
                }
                
                if !autoMatched.isEmpty {
                    Section(header: Text("Auto-Matched").foregroundColor(.green)) {
                        ForEach(autoMatched) { item in
                            if case .matched(let pdf) = item.resolution {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                    VStack(alignment: .leading) {
                                        Text(pdf.name).font(.subheadline)
                                        Text(item.request.originalText).font(.caption2).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                
                if !missing.isEmpty {
                    Section(header: Text("Missing (Still Need)").foregroundColor(.red)) {
                        ForEach(missing) { item in
                            HStack {
                                Image(systemName: "xmark.circle").foregroundColor(.red)
                                Text(item.request.originalText).font(.subheadline)
                            }
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
                        
                        Button {
                            buildOmnibusSequence()
                        } label: {
                            Label("Compile Kindle Omnibus (\(omnibusTotalMB)MB)", systemImage: "books.vertical.fill")
                        }
                    }
                    .font(.headline)
                    .disabled(autoMatched.isEmpty)
                }
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
    
    private func buildEventCollection() {
        isProcessing = true
        
        // Extract array of matched PDFs exactly in the order of the resolvedItems list
        var orderedIDs: [UUID] = []
        
        for item in resolvedItems {
            if case .matched(let pdf) = item.resolution {
                orderedIDs.append(pdf.id)
            }
        }
        
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
}

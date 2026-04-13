import SwiftUI

/// A modal sheet that shows ALL series visible in the library — both metadata-derived
/// series groups AND custom collections — so the user can explicitly pick which one
/// to organize volume sub-folders into.
struct SeriesPickerSheet: View {
    @Environment(\.dismiss) var dismiss
    
    let collections: [PDFCollection]
    let eventName: String
    let onSelection: (PDFCollection?) -> Void
    
    // We also need the full library to build metadata-derived series
    @EnvironmentObject var conversionManager: ConversionManager
    
    @State private var searchText = ""
    
    /// Represents a selectable series in the picker
    struct PickableSeriesItem: Identifiable {
        let id: String
        let name: String
        let issueCount: Int
        let icon: String
        let color: Color
        let collection: PDFCollection? // nil = metadata-derived series
    }
    
    /// Build the full list of pickable series from both collections and metadata series
    var allSeriesItems: [PickableSeriesItem] {
        var items: [PickableSeriesItem] = []
        var seenNames = Set<String>()
        
        // 1. PDFCollections (manually created series/event folders)
        for col in collections {
            items.append(PickableSeriesItem(
                id: "col_\(col.id.uuidString)",
                name: col.name,
                issueCount: conversionManager.convertedPDFs.filter { $0.collectionId == col.id }.count,
                icon: col.icon,
                color: colorFor(col.color),
                collection: col
            ))
            seenNames.insert(col.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        // 2. Metadata-derived series (grouped by pdf.metadata.series)
        var seriesBuckets: [String: Int] = [:]
        for pdf in conversionManager.convertedPDFs {
            if let seriesName = pdf.metadata.series, !seriesName.isEmpty {
                seriesBuckets[seriesName, default: 0] += 1
            }
        }
        
        for (seriesName, count) in seriesBuckets {
            let normalizedName = seriesName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip if there's already a collection with this exact name (dedup)
            if seenNames.contains(normalizedName) { continue }
            
            items.append(PickableSeriesItem(
                id: "series_\(seriesName)",
                name: seriesName,
                issueCount: count,
                icon: "books.vertical",
                color: Theme.blue,
                collection: nil // Will create a new PDFCollection from this metadata series
            ))
        }
        
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    var filteredItems: [PickableSeriesItem] {
        if searchText.isEmpty { return allSeriesItems }
        return allSeriesItems.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Suggested match section
                let suggested = allSeriesItems.filter {
                    $0.name.localizedCaseInsensitiveContains(eventName) ||
                    eventName.localizedCaseInsensitiveContains($0.name)
                }
                
                if !suggested.isEmpty {
                    Section {
                        ForEach(suggested) { item in
                            seriesRow(item, badge: "Suggested")
                        }
                    } header: {
                        Label("Best Matches", systemImage: "sparkles")
                            .foregroundColor(Theme.orange)
                    }
                }
                
                // Create New option
                Section {
                    Button {
                        onSelection(nil)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.green)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Create New Series")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(Theme.text)
                                Text("Named: \"\(eventName)\"")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textSecondary)
                            }
                            
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                
                // All library series
                Section {
                    if filteredItems.isEmpty {
                        Text("No matching series found")
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                    } else {
                        ForEach(filteredItems) { item in
                            seriesRow(item, badge: nil)
                        }
                    }
                } header: {
                    Text("Library Series (\(filteredItems.count))")
                }
            }
            .searchable(text: $searchText, prompt: "Search library series...")
            .listStyle(.insetGrouped)
            .navigationTitle("Select Target Series")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
    
    @ViewBuilder
    private func seriesRow(_ item: PickableSeriesItem, badge: String?) -> some View {
        Button {
            if let existingCol = item.collection {
                // Existing PDFCollection — use directly
                onSelection(existingCol)
            } else {
                // Metadata-derived series — create a new PDFCollection for it
                let newCol = PDFCollection(
                    id: UUID(),
                    name: item.name,
                    icon: "books.vertical",
                    color: "orange",
                    creationDate: Date()
                )
                conversionManager.collections.append(newCol)
                
                // Also assign all existing files in this metadata series to the new collection
                for i in conversionManager.convertedPDFs.indices {
                    if conversionManager.convertedPDFs[i].metadata.series?.lowercased() == item.name.lowercased(),
                       conversionManager.convertedPDFs[i].collectionId == nil {
                        conversionManager.convertedPDFs[i].collectionId = newCol.id
                    }
                }
                
                onSelection(newCol)
            }
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: 20))
                    .foregroundColor(item.color)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    
                    HStack(spacing: 6) {
                        Text("\(item.issueCount) issues")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                        
                        if item.collection != nil {
                            Text("Collection")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.blue)
                                .clipShape(Capsule())
                        } else {
                            Text("Series")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.textSecondary)
                                .clipShape(Capsule())
                        }
                    }
                }
                
                Spacer()
                
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.orange)
                        .clipShape(Capsule())
                }
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

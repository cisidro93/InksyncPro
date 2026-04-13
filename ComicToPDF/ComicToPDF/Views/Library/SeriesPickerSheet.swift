import SwiftUI

/// A modal sheet that lets the user explicitly select which existing series/collection
/// to organize volume sub-folders into, or create a new one.
struct SeriesPickerSheet: View {
    @Environment(\.dismiss) var dismiss
    
    let collections: [PDFCollection]
    let eventName: String
    let onSelection: (PDFCollection?) -> Void
    
    @State private var searchText = ""
    @State private var showingNewSeriesAlert = false
    @State private var newSeriesName = ""
    
    var filteredCollections: [PDFCollection] {
        if searchText.isEmpty {
            return collections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return collections
            .filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Suggested match section (if event name loosely matches a collection)
                let suggested = collections.filter {
                    $0.name.localizedCaseInsensitiveContains(eventName) ||
                    eventName.localizedCaseInsensitiveContains($0.name)
                }
                
                if !suggested.isEmpty {
                    Section {
                        ForEach(suggested) { col in
                            collectionRow(col, badge: "Suggested")
                        }
                    } header: {
                        Label("Best Matches", systemImage: "sparkles")
                            .foregroundColor(Theme.orange)
                    }
                }
                
                // Create New option
                Section {
                    Button {
                        onSelection(nil) // nil = create new from eventName
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
                
                // All collections
                Section {
                    if filteredCollections.isEmpty {
                        Text("No matching series found")
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                    } else {
                        ForEach(filteredCollections) { col in
                            collectionRow(col, badge: nil)
                        }
                    }
                } header: {
                    Text("All Library Series (\(filteredCollections.count))")
                }
            }
            .searchable(text: $searchText, prompt: "Search series...")
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
    private func collectionRow(_ col: PDFCollection, badge: String?) -> some View {
        Button {
            onSelection(col)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: col.icon)
                    .font(.system(size: 20))
                    .foregroundColor(colorFor(col.color))
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(col.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    
                    Text("Created \(col.creationDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
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

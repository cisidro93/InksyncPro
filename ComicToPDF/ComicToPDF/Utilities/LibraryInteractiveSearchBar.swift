import SwiftUI

// ✅ FIX: Restored Search Bar Struct
struct LibraryInteractiveSearchBar: View {
    @Binding var isGridView: Bool
    @Binding var isSelectionMode: Bool
    @Binding var searchText: String
    @Binding var gridColumns: Int
    @Binding var sortMethod: OrganizationMethod
    var onSelectAll: () -> Void

    var body: some View {
        VStack(spacing: 12) {
             HStack {
                 HStack {
                     Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                     TextField("Search library...", text: $searchText)
                 }
                 .padding(8)
                 .background(Color(.systemGray6))
                 .cornerRadius(8)

                 // View Toggle
                 Button(action: { isGridView.toggle() }) {
                     Image(systemName: isGridView ? "square.grid.2x2" : "list.bullet")
                 }
                 .padding(.leading, 4)

                 // Sort Menu
                 Menu {
                     Picker("Sort By", selection: $sortMethod) {
                         ForEach(OrganizationMethod.allCases) { method in
                             Text(method.rawValue).tag(method)
                         }
                     }
                 } label: {
                     Image(systemName: "arrow.up.arrow.down.circle")
                 }
                 
                 // Column Slider (Grid Only)
                 if isGridView {
                    Menu {
                        Picker("Columns", selection: $gridColumns) {
                            Text("2 Columns").tag(2)
                            Text("3 Columns").tag(3)
                            Text("4 Columns").tag(4)
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                 }
                 
                 // Selection Mode
                 Button(action: { isSelectionMode.toggle() }) {
                     Text(isSelectionMode ? "Done" : "Select")
                         .fontWeight(.bold)
                 }
                 .padding(.leading, 4)
                 
                 if isSelectionMode {
                      Button("All", action: onSelectAll)
                 }
             }
        }
        .padding(.vertical, 8)
        .padding(.horizontal)
    }
}

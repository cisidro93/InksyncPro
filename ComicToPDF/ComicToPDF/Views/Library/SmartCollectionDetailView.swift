import SwiftUI

struct SmartCollectionDetailView: View {
    let rule: SmartCollectionRule
    @StateObject private var viewModel: SmartCollectionViewModel
    @Environment(\.dismiss) var dismiss
    
    // UI Layout state mapped from main library to ensure consistency
    @State private var viewStyle: ModernLibraryView.LibraryViewStyle = .grid
    @State private var sortOption: ModernLibraryView.SortOption = .recentlyAdded // Not functionally modifying viewModel sort yet, but keeps UI state intact
    
    // Dummy bindings required by shared components
    @State private var mockBatchMode = false
    @State private var mockMultiSelection: Set<UUID> = []
    
    init(rule: SmartCollectionRule) {
        self.rule = rule
        self._viewModel = StateObject(wrappedValue: SmartCollectionViewModel(rule: rule))
    }
    
    var body: some View {
        ZStack {
            Theme.background.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: rule.iconName)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(rule.tintColor.gradient)
                    
                    Text(rule.rawValue)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(Theme.text)
                    
                    Spacer()
                    
                    Text("\(viewModel.filteredPDFs.count) ITEMS")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.textSecondary)
                        .tracking(1.0)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.surface)
                        .clipShape(Capsule())
                    
                    Button {
                        withAnimation { viewStyle = viewStyle == .grid ? .list : .grid }
                    } label: {
                        Image(systemName: viewStyle == .grid ? "list.bullet" : "square.grid.2x2")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                
                Divider().background(Theme.text.opacity(0.1))
                
                if viewModel.filteredPDFs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray.fill")
                            .font(.system(size: 40))
                            .foregroundColor(Theme.text.opacity(0.2))
                        Text("No items found.")
                            .foregroundColor(Theme.textSecondary)
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        if viewStyle == .grid {
                            LibraryGridView(
                                items: viewModel.filteredPDFs.map { .single($0) },
                                tapAction: .constant(.read),
                                isBatchMode: $mockBatchMode,
                                multiSelection: $mockMultiSelection,
                                onSelectAll: {}
                            )
                            .padding(.top, 16)
                        } else {
                            LibraryListView(
                                items: viewModel.filteredPDFs.map { .single($0) },
                                tapAction: .constant(.read),
                                isBatchMode: $mockBatchMode,
                                multiSelection: $mockMultiSelection
                            )
                            .padding(.top, 16)
                        }
                    }
                }
            }
        }
        .navigationBarHidden(true)
    }
}

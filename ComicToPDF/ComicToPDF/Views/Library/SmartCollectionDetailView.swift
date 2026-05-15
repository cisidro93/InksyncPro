import SwiftUI

struct SmartCollectionDetailView: View {
    let rule: SmartCollectionRule
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    
    // UI Layout state mapped from main library to ensure consistency
    @State private var viewStyle: ModernLibraryView.LibraryViewStyle = .grid
    @State private var sortOption: ModernLibraryView.SortOption = .dateAdded
    
    // Dummy bindings required by shared components
    @State private var mockBatchMode = false
    @State private var mockMultiSelection: Set<UUID> = []
    
    // Force view updates when tracker changes
    @ObservedObject private var tracker = ReaderProgressTracker.shared
    
    var filteredPDFs: [ConvertedPDF] {
        let allPDFs = conversionManager.convertedPDFs
        var results: [ConvertedPDF] = []
        
        switch rule {
        case .recentlyAdded:
            results = allPDFs.sorted(by: { $0.dateAdded > $1.dateAdded })
            if results.count > 50 {
                results = Array(results.prefix(50))
            }
            
        case .readingNow:
            results = allPDFs.filter { pdf in
                let maxPages = max(pdf.pageCount, 1)
                let read = pdf.metadata.lastReadPage ?? 0
                return read > 0 && read < (maxPages - 1)
            }
            results.sort(by: { pdf1, pdf2 in
                let d1 = tracker.progress(for: pdf1.id)?.lastOpenedAt ?? Date.distantPast
                let d2 = tracker.progress(for: pdf2.id)?.lastOpenedAt ?? Date.distantPast
                return d1 > d2
            })
            
        case .allUnread:
            results = allPDFs.filter { pdf in
                let read = pdf.metadata.lastReadPage ?? 0
                return read == 0
            }
            results.sort(by: { $0.dateAdded > $1.dateAdded })
            
        case .completed:
            results = allPDFs.filter { pdf in
                let maxPages = max(pdf.pageCount, 1)
                let read = pdf.metadata.lastReadPage ?? 0
                return read >= (maxPages - 1)
            }
            results.sort(by: { pdf1, pdf2 in
                let d1 = tracker.progress(for: pdf1.id)?.lastOpenedAt ?? Date.distantPast
                let d2 = tracker.progress(for: pdf2.id)?.lastOpenedAt ?? Date.distantPast
                return d1 > d2
            })
            
        case .manga:
            results = allPDFs.filter { pdf in
                return tracker.progress(for: pdf.id)?.prefersMangaMode == true
            }
            results.sort(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        
        return results
    }
    
    var body: some View {
        ZStack {
            Theme.bg.edgesIgnoringSafeArea(.all)
            
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
                    
                    Text("\(filteredPDFs.count) ITEMS")
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
                
                if filteredPDFs.isEmpty {
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
                                items: filteredPDFs.map { .single($0) },
                                tapAction: .constant(.read),
                                isBatchMode: $mockBatchMode,
                                multiSelection: $mockMultiSelection,
                                onSelectAll: {}
                            )
                            .padding(.top, 16)
                        } else {
                            LibraryListView(
                                items: filteredPDFs.map { .single($0) },
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

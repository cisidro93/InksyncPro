import SwiftUI

struct SeriesDetailView: View {
    let series: SeriesGroup
    @EnvironmentObject var conversionManager: ConversionManager
    @Binding var selectedPDF: ConvertedPDF?
    var useNavigationStack: Bool
    
    @State private var sortOrder: SortOrder = .ascending
    @State private var headerCover: UIImage? = nil
    
    // Batch Selection
    @State private var selection = Set<UUID>()
    @State private var isSelectionMode: Bool = false
    @State private var showingMergeConfig: Bool = false

    enum SortOrder { case ascending, descending }

    var sortedIssues: [ConvertedPDF] {
        sortOrder == .ascending ? series.issues : series.issues.reversed()
    }

    var body: some View {
        List {
            Section(header: headerView) {
                ForEach(sortedIssues) { pdf in
                    if isSelectionMode {
                        Button {
                            if selection.contains(pdf.id) {
                                selection.remove(pdf.id)
                            } else {
                                selection.insert(pdf.id)
                            }
                        } label: {
                            HStack {
                                LibraryPDFRowWithCover(pdf: pdf, isSelected: false)
                                Spacer()
                                Image(systemName: selection.contains(pdf.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selection.contains(pdf.id) ? .blue : .gray)
                                    .font(.title2)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .listRowBackground(selection.contains(pdf.id) ? Color.blue.opacity(0.1) : Color.black)
                        
                    } else if useNavigationStack {
                        NavigationLink(value: pdf) {
                            LibraryPDFRowWithCover(pdf: pdf, isSelected: false)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                conversionManager.deletePDF(pdf)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    } else {
                        Button {
                            selectedPDF = pdf
                        } label: {
                            LibraryPDFRowWithCover(pdf: pdf, isSelected: selectedPDF?.id == pdf.id)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .listRowBackground(selectedPDF?.id == pdf.id ? Theme.surfaceElevated : Color.black)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                conversionManager.deletePDF(pdf)
                                if selectedPDF?.id == pdf.id { selectedPDF = nil }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(series.title)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button(action: {
                        withAnimation {
                            isSelectionMode.toggle()
                            selection.removeAll()
                        }
                    }) {
                        Text(isSelectionMode ? "Cancel" : "Select")
                            .bold(isSelectionMode)
                    }
                    
                    if !isSelectionMode {
                        Menu {
                            Picker("Sort", selection: $sortOrder) {
                                Text("Oldest First").tag(SortOrder.ascending)
                                Text("Newest First").tag(SortOrder.descending)
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                    }
                }
            }
            
            ToolbarItemGroup(placement: .bottomBar) {
                if isSelectionMode {
                    Button(action: {
                        showingMergeConfig = true
                    }) {
                        Text("Convert & Merge")
                            .bold()
                    }
                    .disabled(selection.count < 2)
                    
                    Spacer()
                    
                    Text("\(selection.count) Selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .sheet(isPresented: $showingMergeConfig) {
            let filesToMerge = series.issues.filter { selection.contains($0.id) }
            SeriesMergeConfigurationView(sourceFiles: filesToMerge)
        }
        .task(id: series.id) { await loadHeaderCover() }
    }

    var headerView: some View {
        HStack {
            if let img = headerCover {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 120)
                    .cornerRadius(8)
                    .shadow(radius: 4)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color(UIColor.secondarySystemBackground))
                    .frame(width: 80, height: 120)
                    .overlay(Image(systemName: "books.vertical").foregroundColor(.gray))
                    .cornerRadius(8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(series.title)
                    .font(.title2).bold()
                    .foregroundColor(.primary)
                Text("\(series.count) Issues")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if let publisher = series.issues.first?.metadata.publisher {
                    Text(publisher)
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.top, 4)
                }
            }
            .padding(.leading)
            Spacer()
        }
        .padding(.vertical)
    }

    private func loadHeaderCover() async {
        guard let url = series.coverURL else { return }
        let img = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return UIImage?.none }
            return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 160, height: 240))
        }.value
        await MainActor.run { headerCover = img }
    }
}


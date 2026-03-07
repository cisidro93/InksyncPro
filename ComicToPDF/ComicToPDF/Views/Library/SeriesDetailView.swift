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
    @State private var showBatchMetadataEditor: Bool = false
    
    // Context Menu State
    @State private var pdfToRename: ConvertedPDF?
    @State private var renameText = ""
    @State private var pdfToExport: ConvertedPDF?
    @State private var pdfToSearchMetadata: ConvertedPDF?
    @State private var pdfToAssignSeries: ConvertedPDF?
    @State private var assignSeriesText = ""

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
                        .swipeActions(edge: .leading) { swipeActionsLeading(pdf) }
                        .swipeActions(edge: .trailing) { swipeActionsTrailing(pdf) }
                        .contextMenu { contextMenuContent(pdf) }
                    } else {
                        Button {
                            selectedPDF = pdf
                        } label: {
                            LibraryPDFRowWithCover(pdf: pdf, isSelected: selectedPDF?.id == pdf.id)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .listRowBackground(selectedPDF?.id == pdf.id ? Theme.surfaceElevated : Color.black)
                        .swipeActions(edge: .leading) { swipeActionsLeading(pdf) }
                        .swipeActions(edge: .trailing) { swipeActionsTrailing(pdf) }
                        .contextMenu { contextMenuContent(pdf) }
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
        }
        .safeAreaInset(edge: .bottom) {
            if isSelectionMode {
                VStack(spacing: 0) {
                    Divider().background(Color.white.opacity(0.1))
                    
                    HStack(spacing: 16) {
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            showBatchMetadataEditor = true
                        }) {
                            HStack {
                                Image(systemName: "sparkles")
                                Text("Intelligent Metadata")
                            }
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(alignment: .center) {
                                if selection.isEmpty {
                                    Color.gray.opacity(0.3)
                                } else {
                                    LinearGradient(colors: [Theme.blue, Theme.blue.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                }
                            }
                            .clipShape(Capsule())
                            .shadow(color: selection.isEmpty ? .clear : Theme.blue.opacity(0.3), radius: 5, y: 3)
                        }
                        .disabled(selection.isEmpty)
                        
                        Spacer()
                        
                        Text("\(selection.count) Selected")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            showingMergeConfig = true
                        }) {
                            HStack {
                                Text("Merge")
                                Image(systemName: "doc.on.doc.fill")
                            }
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(alignment: .center) {
                                if selection.count < 2 {
                                    Color.gray.opacity(0.3)
                                } else {
                                    LinearGradient(colors: [Color.purple, Color.purple.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                }
                            }
                            .clipShape(Capsule())
                            .shadow(color: selection.count < 2 ? .clear : Color.purple.opacity(0.3), radius: 5, y: 3)
                        }
                        .disabled(selection.count < 2)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .ignoresSafeArea(edges: .bottom)
                            .shadow(color: .black.opacity(0.2), radius: 10, y: -5)
                    )
                }
                .transition(.move(edge: .bottom))
            }
        }
        .sheet(isPresented: $showingMergeConfig) {
            let filesToMerge = series.issues.filter { selection.contains($0.id) }
            SeriesMergeConfigurationView(sourceFiles: filesToMerge)
        }
        .sheet(isPresented: $showBatchMetadataEditor) {
            let selectedFiles = series.issues.filter { selection.contains($0.id) }
            BatchMetadataEditorView(selectedPDFs: selectedFiles)
        }
        .sheet(item: $pdfToExport) { pdf in
            DualExportView(pdf: pdf)
        }
        .sheet(item: $pdfToSearchMetadata) { pdf in
            MetadataSearchSheet(pdf: pdf)
        }
        .alert("Rename File", isPresented: Binding(
            get: { pdfToRename != nil },
            set: { if !$0 { pdfToRename = nil } }
        )) {
            TextField("New Name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if let pdf = pdfToRename {
                    conversionManager.renamePDF(pdf, to: renameText)
                }
            }
        }
        .alert("Add to Series", isPresented: Binding(
            get: { pdfToAssignSeries != nil },
            set: { if !$0 { pdfToAssignSeries = nil } }
        )) {
            TextField("Series Name", text: $assignSeriesText)
            Button("Cancel", role: .cancel) { pdfToAssignSeries = nil }
            Button("Assign") {
                if let pdf = pdfToAssignSeries {
                    let name = assignSeriesText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        conversionManager.assignToSeries(pdf, seriesName: name)
                    }
                }
                pdfToAssignSeries = nil
            }
        } message: {
            Text("Enter the series name to group this file into a collection.")
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

    @ViewBuilder
    private func swipeActionsLeading(_ pdf: ConvertedPDF) -> some View {
        Button {
            pdfToExport = pdf
        } label: { Label("Export", systemImage: "square.and.arrow.up") }
        .tint(.green)
    
        Button {
            pdfToSearchMetadata = pdf
        } label: { Label("Metadata", systemImage: "info.circle") }
        .tint(.blue)
        
        Button {
            renameText = pdf.name
            pdfToRename = pdf
        } label: { Label("Rename", systemImage: "pencil") }
        .tint(.orange)
        
        Button {
            Task { await conversionManager.embedPanels(for: pdf) }
        } label: { Label("Embed", systemImage: "flame") }
        .tint(.purple)
    }
    
    @ViewBuilder
    private func swipeActionsTrailing(_ pdf: ConvertedPDF) -> some View {
        Button(role: .destructive) { conversionManager.deletePDF(pdf) } label: { Label("Delete", systemImage: "trash") }
    }
    
    @ViewBuilder
    private func contextMenuContent(_ pdf: ConvertedPDF) -> some View {
        Button {
            pdfToExport = pdf
        } label: { Label("Export Options", systemImage: "square.and.arrow.up") }
        
        Button {
            renameText = pdf.name
            pdfToRename = pdf
        } label: { Label("Rename", systemImage: "pencil") }
        
        Button {
            assignSeriesText = pdf.metadata.series ?? ""
            pdfToAssignSeries = pdf
        } label: { Label("Add to Series...", systemImage: "books.vertical") }
        
        if (pdf.metadata.series != nil && !pdf.metadata.series!.isEmpty) || pdf.collectionId != nil {
            Button {
                conversionManager.setExplicitSeriesCover(for: pdf)
            } label: { Label("Set as Series Cover", systemImage: "photo.on.rectangle") }
        }
        
        Button {
            Task { await conversionManager.embedPanels(for: pdf) }
        } label: { Label("Embed Panels", systemImage: "flame") }
        
        Button(role: .destructive) { conversionManager.deletePDF(pdf) } label: { Label("Delete", systemImage: "trash") }
        Divider()
        Button {
            pdfToSearchMetadata = pdf
        } label: { Label("Fetch Metadata", systemImage: "magnifyingglass") }
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


import SwiftUI

// ============================================================================
// MARK: - LIBRARY VIEW
// ============================================================================

struct LibraryView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Binding var selectedTab: Int // ✅ ADDED BINDING
    @State private var isGridView = true // ✅ Step 3 Checkpoint
    @State private var isSelectionMode = false
    @State private var selectedPDFs: Set<UUID> = []
    @State private var selectedPDF: ConvertedPDF?
    @State private var showingActionSheet = false
    @State private var showingPreview = false
    @State private var showingMetadataEditor = false
    @State private var showingPageReorder = false
    @State private var showingMoveToCollection = false
    @State private var showingShareSheet = false
    @State private var showingDevicePicker = false
    @State private var showingDeleteAlert = false
    @State private var showingCloudExport = false
    @State private var showingBatchMail = false
    @State private var showingBatchShare = false
    @State private var showingBatchDelete = false
    @State private var showingBatchCloudExport = false

    @State private var showingFilters = false
    @State private var showingMerge = false
    @State private var showingDuplicates = false
    @State private var showingPageExtraction = false
    @State private var showingBatchRename = false
    
    @State private var showingPageDelete = false
    @State private var showingSplitPDF = false
    @State private var showingRenameFile = false
    
    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(colors: [Color(.systemBackground), Color.blue.opacity(0.05)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                if conversionManager.convertedPDFs.isEmpty {
                    emptyStateLibrary
                } else if conversionManager.filteredPDFs.isEmpty {
                    emptyStateSearch
                } else {
                    VStack(spacing: 0) {
                        SearchFilterBar(searchText: $conversionManager.searchText, showFilters: $showingFilters)
                        
                        // Active Tasks Monitor
                        if !conversionManager.activeTasks.isEmpty {
                            VStack(spacing: 8) {
                                ForEach(conversionManager.activeTasks) { task in
                                    TaskMonitorRow(task: task)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                        }
                        
                        if isSelectionMode { batchActionBar }
                        
                        if isGridView {
                            pdfGrid
                        } else {
                            pdfList
                        }
                    }
                }
            }
            .navigationTitle("Library")
                
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !conversionManager.convertedPDFs.isEmpty {
                        Button(isSelectionMode ? "Cancel" : "Select") { 
                            HapticManager.shared.impact(.light)
                            withAnimation { isSelectionMode.toggle(); if !isSelectionMode { selectedPDFs.removeAll() } } 
                        }
                    }
                    
                    Button(action: { isGridView.toggle() }) {
                        Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                    }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if isSelectionMode {
                            Button(selectedPDFs.count == conversionManager.convertedPDFs.count ? "Deselect All" : "Select All") {
                                HapticManager.shared.impact(.light)
                                if selectedPDFs.count == conversionManager.convertedPDFs.count { selectedPDFs.removeAll() }
                                else { selectedPDFs = Set(conversionManager.convertedPDFs.map { $0.id }) }
                            }
                        } else {
                            Menu {
                                Button(action: { showingMerge = true }) { Label("Merge PDFs", systemImage: "doc.on.doc") }
                                Button(action: { showingBatchRename = true }) { Label("Batch Rename", systemImage: "pencil.circle") }
                                Button(action: { showingDuplicates = true }) { Label("Find Duplicates", systemImage: "doc.on.doc.fill") }
                                Divider()
                                Button(action: { importFromExternalStorage() }) { Label("Import from USB/Files", systemImage: "externaldrive") }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showingPreview) { if let pdf = selectedPDF { PDFPreviewView(pdf: pdf) } }
        .sheet(isPresented: $showingMetadataEditor) { if let pdf = selectedPDF { MetadataEditorView(pdf: pdf) } }
        .sheet(isPresented: $showingPageReorder) { if let pdf = selectedPDF { PageReorderView(pdf: pdf) } }
        .sheet(isPresented: $showingMoveToCollection) { if let pdf = selectedPDF { MoveToCollectionView(pdf: pdf) } }
        .sheet(isPresented: $showingShareSheet) { if let pdf = selectedPDF { ShareSheet(items: [pdf.url]) } }
        .sheet(isPresented: $showingDevicePicker) { if let pdf = selectedPDF { KindleDevicePickerView(pdfURLs: [pdf.url]) } }
        .sheet(isPresented: $showingCloudExport) { if let pdf = selectedPDF { CloudExportView(pdfsToExport: [pdf]) } }
        .sheet(isPresented: $showingBatchMail) { KindleDevicePickerView(pdfURLs: getSelectedURLs()) }
        .sheet(isPresented: $showingBatchShare) { ShareSheet(items: getSelectedURLs()) }
        .sheet(isPresented: $showingBatchCloudExport) { CloudExportView(pdfsToExport: getSelectedPDFs()) }
        .sheet(isPresented: $showingMerge) { PDFMergeView() }
        .sheet(isPresented: $showingDuplicates) { NavigationView { DuplicateDetectionView() } }
        .sheet(isPresented: $showingPageExtraction) { if let pdf = selectedPDF { PageExtractionView(pdf: pdf) } }
        .sheet(isPresented: $showingBatchRename) { BatchRenameView() }
        .sheet(isPresented: $showingPageDelete) { if let pdf = selectedPDF { PageDeleteView(pdf: pdf) } }
        .sheet(isPresented: $showingSplitPDF) { if let pdf = selectedPDF { SplitPDFView(pdf: pdf) } }
        .sheet(isPresented: $showingRenameFile) { if let pdf = selectedPDF { RenameFileView(pdf: pdf) } }
        .alert("Delete PDF?", isPresented: $showingDeleteAlert) { Button("Cancel", role: .cancel) { }; Button("Delete", role: .destructive) { if let pdf = selectedPDF { conversionManager.removeFromLibrary(pdf) } } }
        .alert("Delete \(selectedPDFs.count) PDFs?", isPresented: $showingBatchDelete) { Button("Cancel", role: .cancel) { }; Button("Delete All", role: .destructive) { for pdf in getSelectedPDFs() { conversionManager.removeFromLibrary(pdf) }; selectedPDFs.removeAll(); isSelectionMode = false } }
        .confirmationDialog("Filter Options", isPresented: $showingFilters) {
            Button("Sort by Date Added") { conversionManager.sortOption = .dateAdded }
            Button("Sort by Name") { conversionManager.sortOption = .name }
            Button("Sort by Size") { conversionManager.sortOption = .size }
            Button("Sort by Pages") { conversionManager.sortOption = .pageCount }
            Button(conversionManager.filterFavoritesOnly ? "Show All PDFs" : "Show Favorites Only") { conversionManager.filterFavoritesOnly.toggle() }
            if conversionManager.filterCollection != nil { Button("Clear Collection Filter") { conversionManager.filterCollection = nil } }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("PDF Options", isPresented: $showingActionSheet) {
            Button("Toggle Favorite") { conversionManager.toggleFavorite(selectedPDF!) }
            Button("Extract Pages") { showingPageExtraction = true }
            Button("Preview") { showingPreview = true }
            Button("Send to Kindle") { showingDevicePicker = true }
            Button("Export to Cloud") { showingCloudExport = true }
            Button("Share") { showingShareSheet = true }
            Button("Edit Metadata") { showingMetadataEditor = true }
            Button("Reorder Pages") { showingPageReorder = true }
            Button("Move to Collection") { showingMoveToCollection = true }
            Button("Split PDF") { showingSplitPDF = true }
            Button("Rename") { showingRenameFile = true }
            Button("Delete Pages") { showingPageDelete = true }
            Button("Delete", role: .destructive) { showingDeleteAlert = true }
            Button("Cancel", role: .cancel) { }
        }
    }
    
    private var emptyStateLibrary: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical").font(.system(size: 60)).foregroundColor(.secondary.opacity(0.5))
            Text("No Converted PDFs").font(.title2).fontWeight(.semibold)
            Text("Convert some CBZ/CBR files to see them here").font(.subheadline).foregroundColor(.secondary)
            Button("Go to Convert") {
                selectedTab = 0 // ✅ SWITCH TO CONVERT TAB
            }
            .padding(.top, 10)
        }
    }
    
    private var emptyStateSearch: some View {
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass").font(.system(size: 60)).foregroundColor(.secondary.opacity(0.5))
            Text("No Matches Found").font(.title2).fontWeight(.semibold)
            Text("Try adjusting your search or filters").font(.subheadline).foregroundColor(.secondary)
            Button("Clear Filters") {
                withAnimation {
                    conversionManager.searchText = ""
                    conversionManager.filterFavoritesOnly = false
                    conversionManager.filterCollection = nil
                    HapticManager.shared.notification(.success)
                }
            }
            .buttonStyle(.bordered)
        }
    }
    
    private var batchActionBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("\(selectedPDFs.count) selected").font(.subheadline).foregroundColor(.secondary)
                Spacer()
                Button(action: { showingBatchMail = true }) { VStack(spacing: 4) { Image(systemName: "paperplane.fill").font(.title3); Text("Kindle").font(.caption2) }.foregroundColor(selectedPDFs.isEmpty ? .gray : .orange) }.disabled(selectedPDFs.isEmpty)
                Button(action: { showingBatchCloudExport = true }) { VStack(spacing: 4) { Image(systemName: "icloud.and.arrow.up").font(.title3); Text("Cloud").font(.caption2) }.foregroundColor(selectedPDFs.isEmpty ? .gray : .blue) }.disabled(selectedPDFs.isEmpty)
                Button(action: { showingBatchShare = true }) { VStack(spacing: 4) { Image(systemName: "square.and.arrow.up").font(.title3); Text("Share").font(.caption2) }.foregroundColor(selectedPDFs.isEmpty ? .gray : .green) }.disabled(selectedPDFs.isEmpty)
                Button(action: { exportToExternalStorage(pdfs: getSelectedPDFs()) }) { VStack(spacing: 4) { Image(systemName: "externaldrive.fill").font(.title3); Text("USB").font(.caption2) }.foregroundColor(selectedPDFs.isEmpty ? .gray : .purple) }.disabled(selectedPDFs.isEmpty)
                Button(action: { showingBatchDelete = true }) { VStack(spacing: 4) { Image(systemName: "trash.fill").font(.title3); Text("Delete").font(.caption2) }.foregroundColor(selectedPDFs.isEmpty ? .gray : .red) }.disabled(selectedPDFs.isEmpty)
            }.padding(.horizontal).padding(.vertical, 12).background(Color(.secondarySystemBackground))
            if !selectedPDFs.isEmpty {
                HStack { Image(systemName: "doc.fill").foregroundColor(.secondary); Text("Total: \(formatBytes(calculateSelectedSize()))").font(.caption).foregroundColor(.secondary); Spacer() }.padding(.horizontal).padding(.vertical, 8).background(Color(.tertiarySystemBackground))
            }
        }
    }
    
    private var pdfGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                ForEach(conversionManager.filteredPDFs) { pdf in
                    VStack {
                        if isSelectionMode {
                            ZStack(alignment: .topTrailing) {
                                LibraryGridItem(pdf: pdf)
                                    .opacity(selectedPDFs.contains(pdf.id) ? 0.7 : 1.0)
                                
                                Button(action: { toggleSelection(pdf) }) {
                                    Image(systemName: selectedPDFs.contains(pdf.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title2)
                                        .foregroundColor(selectedPDFs.contains(pdf.id) ? .orange : .gray)
                                        .background(Circle().fill(Color.white))
                                }
                                .padding(8)
                            }
                        } else {
                            Button(action: { selectedPDF = pdf; showingActionSheet = true }) {
                                LibraryGridItem(pdf: pdf)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .contextMenu {
                                Button { selectedPDF = pdf; showingDevicePicker = true } label: { Label("Kindle", systemImage: "paperplane") }
                                Button { selectedPDF = pdf; showingShareSheet = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
                                Button(role: .destructive) { selectedPDF = pdf; showingDeleteAlert = true } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var pdfList: some View {
        List {
            ForEach(conversionManager.filteredPDFs) { pdf in
                HStack(spacing: 12) {
                    if isSelectionMode { Button(action: { toggleSelection(pdf) }) { Image(systemName: selectedPDFs.contains(pdf.id) ? "checkmark.circle.fill" : "circle").font(.title2).foregroundColor(selectedPDFs.contains(pdf.id) ? .orange : .gray) }.buttonStyle(PlainButtonStyle()) }
                    LibraryPDFRowWithCover(pdf: pdf, isSelected: false).contentShape(Rectangle()).onTapGesture { if isSelectionMode { toggleSelection(pdf) } else { selectedPDF = pdf; showingActionSheet = true } }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) { Button(role: .destructive) { selectedPDF = pdf; showingDeleteAlert = true } label: { Label("Delete", systemImage: "trash") } }
                .swipeActions(edge: .leading) {
                    Button { selectedPDF = pdf; showingDevicePicker = true } label: { Label("Kindle", systemImage: "paperplane.fill") }.tint(.orange)
                    Button { exportToExternalStorage(pdfs: [pdf]) } label: { Label("Export (USB)", systemImage: "externaldrive") }.tint(.purple)
                    Button { EPUBDiagnostics.diagnoseEPUB(pdf.url) } label: { Label("Diagnose", systemImage: "ladybug") }.tint(.gray)
                }
            }.onDelete { indexSet in for index in indexSet { conversionManager.removeFromLibrary(conversionManager.convertedPDFs[index]) } }
        }.listStyle(.insetGrouped)
    }
    
    private func importFromExternalStorage() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            return
        }
        
        ExternalStorageManager.shared.selectFileFromExternalStorage(from: rootViewController) { url in
            guard url != nil else { return }
            
            // Add to library
            Task {
                await MainActor.run {
                     // Trigger a reload of the library
                     conversionManager.scanForPDFs()
                }
            }
        }
    }

    private func exportToExternalStorage(pdfs: [ConvertedPDF]) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else { return }
        
        let urls = pdfs.map { $0.url }
        if urls.isEmpty { return }
        
        if urls.count == 1 {
            ExternalStorageManager.shared.exportToExternalStorage(fileURL: urls[0], suggestedName: nil, from: rootViewController) { _, _ in }
        } else {
            ExternalStorageManager.shared.exportMultipleToExternalStorage(fileURLs: urls, from: rootViewController) { _ in }
        }
    }

    private func toggleSelection(_ pdf: ConvertedPDF) { if selectedPDFs.contains(pdf.id) { selectedPDFs.remove(pdf.id) } else { selectedPDFs.insert(pdf.id) } }
    private func getSelectedURLs() -> [URL] { conversionManager.convertedPDFs.filter { selectedPDFs.contains($0.id) }.map { $0.url } }
    private func getSelectedPDFs() -> [ConvertedPDF] { conversionManager.convertedPDFs.filter { selectedPDFs.contains($0.id) } }
    private func calculateSelectedSize() -> Int64 { getSelectedPDFs().reduce(0) { $0 + $1.fileSize } }
    private func formatBytes(_ bytes: Int64) -> String { let formatter = ByteCountFormatter(); formatter.countStyle = .file; return formatter.string(fromByteCount: bytes) }
}

struct LibraryPDFRow: View {
    let pdf: ConvertedPDF
    var body: some View {
        HStack(spacing: 16) {
            ZStack { RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.1)).frame(width: 50, height: 65); Image(systemName: "doc.fill").font(.title2).foregroundColor(.red) }
            VStack(alignment: .leading, spacing: 4) {
                Text(pdf.metadata.title.isEmpty ? pdf.name : pdf.metadata.title).font(.headline).lineLimit(2)
                if !pdf.metadata.series.isEmpty { Text("\(pdf.metadata.series) \(pdf.metadata.volume)").font(.caption).foregroundColor(.orange) }
                HStack(spacing: 8) { Text(pdf.formattedSize); Text("•"); Text("\(pdf.pageCount) pages") }.font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }.padding(.vertical, 4)
    }
}

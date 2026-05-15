import SwiftUI

struct AdvancedWorkspaceView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var focusManager = WorkspaceFocusManager.shared

    let pdf: ConvertedPDF

    @StateObject private var viewModel = PageEditorViewModel()
    @State private var selectedPages: Set<Int> = []

    // UI Architecture State
    @State private var showingInspector: Bool = false
    @State private var activeTab: WorkspaceTab = .pages
    @State private var showingFocusedFilesPicker = false

    // Active PDF — starts as the injected pdf, can be switched via the pinned-file picker
    @State private var activePDFID: UUID

    init(pdf: ConvertedPDF) {
        self.pdf = pdf
        self._activePDFID = State(initialValue: pdf.id)
    }

    enum WorkspaceTab {
        case pages, metadata, chapters, coverStudio
    }
    
    // Live reference uses activePDFID so switching works immediately
    var livePDF: ConvertedPDF {
        conversionManager.convertedPDFs.first(where: { $0.id == activePDFID }) ?? pdf
    }
    
    // Mutable Binding constructor for deep hierarchy views
    var livePDFBinding: Binding<ConvertedPDF> {
        Binding {
            conversionManager.convertedPDFs.first(where: { $0.id == activePDFID }) ?? pdf
        } set: { newValue in
            if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == activePDFID }) {
                conversionManager.convertedPDFs[idx] = newValue
                conversionManager.saveLibrary()
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()
                
                // Main Content Area
                HStack(spacing: 0) {
                    
                    // Left: Canvas Area
                    ZStack(alignment: .bottom) {
                        WorkspaceCanvasView(
                            pdf: livePDF,
                            viewModel: viewModel,
                            selectedPages: $selectedPages
                        )
                        .environmentObject(conversionManager)
                        .padding(.trailing, showingInspector ? 320 : 0) // Leave room for inspector on iPad
                        
                        // Floating Tool Palette
                        WorkspaceToolPalette(
                            pdf: livePDF,
                            viewModel: viewModel,
                            selectedPages: $selectedPages
                        )
                        .environmentObject(conversionManager)
                        .padding(.bottom, 30)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                    // Right: Inspector Panel (iPad/Mac layout)
                    if showingInspector {
                        Divider()
                            .ignoresSafeArea()
                        
                        WorkspaceInspectorView(
                            pdf: livePDFBinding,
                            activeTab: $activeTab
                        )
                        .frame(width: 320)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .transition(.move(edge: .trailing))
                    }
                }
            }
            .navigationTitle(livePDF.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        Task {
                            viewModel.cleanup()
                            dismiss()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundColor(.secondary)
                            Text("Close Workspace")
                                .font(.subheadline.bold())
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(UIColor.tertiarySystemFill))
                        .clipShape(Capsule())
                    }
                }

                // ── Focused Files Picker (center) — only shown when files are pinned ─
                ToolbarItem(placement: .principal) {
                    if !focusManager.isEmpty {
                        Button {
                            showingFocusedFilesPicker = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Color.inkAccentKnowledge)
                                Text("\(focusManager.count) Focused File\(focusManager.count == 1 ? "" : "s")")
                                    .font(.system(size: 13, weight: .semibold))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showingFocusedFilesPicker) {
                            FocusedFilesPopover(activePDFID: $activePDFID, viewModel: viewModel)
                                .environmentObject(conversionManager)
                                .presentationCompactAdaptation(.popover)
                        }
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showingInspector.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.right")
                            .symbolVariant(showingInspector ? .fill : .none)
                    }
                }
            }
            .task(id: activePDFID) {
                // Reload the canvas whenever the active file changes
                viewModel.cleanup()
                selectedPages.removeAll()
                await viewModel.loadPages(from: livePDF)
            }
        }
    }
}

// MARK: - Focused Files Popover
private struct FocusedFilesPopover: View {
    @Binding var activePDFID: UUID
    @ObservedObject var viewModel: PageEditorViewModel
    @ObservedObject private var focusManager = WorkspaceFocusManager.shared
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "pin.fill")
                    .foregroundStyle(Color.inkAccentKnowledge)
                Text("Focused Files")
                    .font(.headline)
                Spacer()
                Button("Clear All") {
                    focusManager.clearAll()
                    dismiss()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if focusManager.isEmpty {
                Text("No files pinned. Long-press any file in the library and tap \"Send to Work Area\".")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                List {
                    ForEach(focusManager.pinnedIDs, id: \.self) { pdfID in
                        if let pdf = conversionManager.convertedPDFs.first(where: { $0.id == pdfID }) {
                            Button {
                                withAnimation(.spring(response: 0.3)) {
                                    activePDFID = pdfID
                                }
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    // Thumbnail
                                    if let img = conversionManager.thumbnailCache.object(forKey: pdfID.uuidString as NSString) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 36, height: 52)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                    } else {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.secondary.opacity(0.2))
                                            .frame(width: 36, height: 52)
                                    }

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(pdf.name)
                                            .font(.system(size: 14, weight: .semibold))
                                            .lineLimit(2)
                                        Text(pdf.contentType.rawValue)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if pdfID == activePDFID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.inkAccentKnowledge)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    focusManager.unpin(pdf)
                                } label: {
                                    Label("Remove", systemImage: "pin.slash")
                                }
                            }
                        }
                    }
                    .onMove { from, to in focusManager.move(fromOffsets: from, toOffset: to) }
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 320, minHeight: 200)
    }
}

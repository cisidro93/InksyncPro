import SwiftUI

struct AdvancedWorkspaceView: View {
    @EnvironmentObject var conversionManager: ConversionManager
    @Environment(\.dismiss) var dismiss
    
    let pdf: ConvertedPDF
    
    @StateObject private var viewModel = PageEditorViewModel()
    @State private var selectedPages: Set<Int> = []
    
    // UI Architecture State
    @State private var showingInspector: Bool = false
    @State private var activeTab: WorkspaceTab = .pages
    
    enum WorkspaceTab {
        case pages, metadata, chapters, coverStudio
    }
    
    // Live reference
    var livePDF: ConvertedPDF {
        conversionManager.convertedPDFs.first(where: { $0.id == pdf.id }) ?? pdf
    }
    
    // Mutable Binding constructor for deep hierarchy views
    var livePDFBinding: Binding<ConvertedPDF> {
        Binding {
            conversionManager.convertedPDFs.first(where: { $0.id == pdf.id }) ?? pdf
        } set: { newValue in
            if let idx = conversionManager.convertedPDFs.firstIndex(where: { $0.id == pdf.id }) {
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
                    Button("Done") {
                        Task {
                            viewModel.cleanup()
                            dismiss()
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
            .task {
                await viewModel.loadPages(from: livePDF)
            }
        }
    }
}

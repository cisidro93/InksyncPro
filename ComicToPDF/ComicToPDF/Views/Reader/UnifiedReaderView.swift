import SwiftUI

struct UnifiedReaderView: View {
    let pdf: ConvertedPDF
    /// All books in the library — used for series-end continuation (next volume).
    var allBooks: [ConvertedPDF] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    
    @State private var showNotebookPanel = false
    @AppStorage("studyNotebookPlacement") private var notebookPlacement: SidebarPlacement = .right
    
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if notebookPlacement == .left && showNotebookPanel && sizeClass == .regular {
                    StudyNotebookView(
                        bookID: pdf.id.uuidString,
                        bookTitle: pdf.name,
                        fileURL: pdf.url
                    )
                    .frame(width: min(geo.size.width * 0.38, 420))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .id("sidebar_notebook_\(pdf.id)")
                    
                    Divider()
                        .background(Color.white.opacity(0.12))
                }
                
                ZStack {
                    Color(hex: "#0a0a0f").edgesIgnoringSafeArea(.all)
                    
                    switch pdf.contentType {
                    case .comic, .manga:
                        ComicReaderEngine(pdf: pdf, onDismiss: { dismiss() }, allBooks: allBooks)
                    case .book:
                        if pdf.url.pathExtension.lowercased() == "pdf" {
                            DocumentReaderEngine(pdf: pdf, onDismiss: { dismiss() })
                        } else {
                            BookReaderEngine(pdf: pdf, onDismiss: { dismiss() }, allBooks: allBooks)
                        }
                    case .hybrid:
                        DocumentReaderEngine(pdf: pdf, onDismiss: { dismiss() })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                if notebookPlacement == .right && showNotebookPanel && sizeClass == .regular {
                    Divider()
                        .background(Color.white.opacity(0.12))
                    
                    StudyNotebookView(
                        bookID: pdf.id.uuidString,
                        bookTitle: pdf.name,
                        fileURL: pdf.url
                    )
                    .frame(width: min(geo.size.width * 0.38, 420))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .id("sidebar_notebook_\(pdf.id)")
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showNotebookPanel)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: notebookPlacement)
        }
        .navigationBarHidden(true)
        .statusBar(hidden: true)
        .forceProMotion()
        .sheet(isPresented: Binding(
            get: { showNotebookPanel && sizeClass == .compact },
            set: { if !$0 { showNotebookPanel = false } }
        )) {
            StudyNotebookView(
                bookID: pdf.id.uuidString,
                bookTitle: pdf.name,
                fileURL: pdf.url,
                showBackButton: true
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleStudyNotebook)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showNotebookPanel.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hideStudyNotebook)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showNotebookPanel = false
            }
        }
    }
}

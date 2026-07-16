import SwiftUI
import ZIPFoundation

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
                        } else if isEPUBComic(pdf: pdf) {
                            ComicReaderEngine(pdf: pdf, onDismiss: { dismiss() }, allBooks: allBooks)
                        } else {
                            BookReaderEngine(pdf: pdf, onDismiss: { dismiss() }, allBooks: allBooks)
                        }
                    case .hybrid:
                        if pdf.url.pathExtension.lowercased() == "epub" {
                            ComicReaderEngine(pdf: pdf, onDismiss: { dismiss() }, allBooks: allBooks)
                        } else {
                            DocumentReaderEngine(pdf: pdf, onDismiss: { dismiss() })
                        }
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
    
    private func isEPUBComic(pdf: ConvertedPDF) -> Bool {
        guard pdf.url.pathExtension.lowercased() == "epub" else { return false }
        
        let resolvedURL: URL
        var accessedURL: URL? = nil
        
        let targetURL = LibraryFileRecord.resolveSandboxURL(pdf.url.absoluteString)
        
        if case .linked(let bm) = pdf.sourceMode,
           let url = try? BookmarkResolver.shared.resolve(bm) {
            let didAccess = url.startAccessingSecurityScopedResource()
            resolvedURL = url
            if didAccess { accessedURL = url }
        } else {
            resolvedURL = targetURL
            let didAccess = resolvedURL.startAccessingSecurityScopedResource()
            if didAccess { accessedURL = resolvedURL }
        }
        
        defer { accessedURL?.stopAccessingSecurityScopedResource() }
        
        do {
            guard let archive = try? Archive(url: resolvedURL, accessMode: .read, pathEncoding: .utf8) else {
                Logger.shared.log("isEPUBComic: Failed to init Archive for \(resolvedURL.path)", category: "Reader", type: .warning)
                return false
            }
            
            var isComic = false
            
            if let containerEntry = archive["META-INF/container.xml"] {
                var containerData = Data()
                _ = try archive.extract(containerEntry) { data in containerData.append(data) }
                
                if let containerStr = String(data: containerData, encoding: .utf8),
                   let opfPath = MetadataHeuristics.extractOPFPath(from: containerStr),
                   let opfEntry = archive[opfPath] {
                    
                    var opfData = Data()
                    _ = try archive.extract(opfEntry) { data in opfData.append(data) }
                    
                    if let opfStr = String(data: opfData, encoding: .utf8) {
                        let lowerOPF = opfStr.lowercased()
                        if lowerOPF.contains("pre-paginated") || 
                           lowerOPF.contains("comic-book") || 
                           lowerOPF.contains("fixed-layout") || 
                           lowerOPF.contains("image-based") ||
                           lowerOPF.contains("manga") {
                            isComic = true
                        }
                    }
                }
            }
            
            // Fallback strategy: check image-to-html ratio
            if !isComic {
                let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic"]
                var imageCount = 0
                var htmlCount = 0
                for entry in archive {
                    let entryPathLower = entry.path.lowercased()
                    let name = (entryPathLower as NSString).lastPathComponent
                    guard !entryPathLower.contains("__macosx"), !name.hasPrefix("._"), name != ".ds_store", !entryPathLower.hasSuffix("/") else { continue }
                    let ext = (name as NSString).pathExtension
                    if imageExtensions.contains(ext) {
                        imageCount += 1
                    } else if ["xhtml", "html", "htm"].contains(ext) {
                        htmlCount += 1
                    }
                }
                if imageCount > 5 && imageCount >= htmlCount - 5 {
                    isComic = true
                }
            }
            
            if isComic {
                return true
            }
        } catch {
            Logger.shared.log("isEPUBComic: Error checking ZIP structure: \(error.localizedDescription)", category: "Reader", type: .warning)
            return false
        }
        return false
    }
}

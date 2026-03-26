$file = "c:\Users\chris\.gemini\antigravity\scratch\InksyncPro\ComicToPDF\ComicToPDF\Views\Reader\ReaderView.swift"

$content = Get-Content -Raw -Encoding UTF8 $file

$targetPDFCall = '(?s)if fileURL\.pathExtension.*?else \{\s*PDFKitView\(url: fileURL\)\s*\.onTapGesture \{\s*withAnimation\(\.easeInOut\(duration: 0\.2\)\) \{\s*isToolbarVisible\.toggle\(\)\s*\}\s*\}\s*\}'
$replacementPDFCall = @"
                    if fileURL.pathExtension.lowercased() != "pdf" {
                        if !pages.isEmpty {
                            PPLReaderView(pages: pages, currentPageIndex: `$currentPageIndex, isMangaMode: isMangaMode) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isToolbarVisible.toggle()
                                }
                            }
                            .ignoresSafeArea()
                        }
                    } else {
                        PDFKitView(
                            url: fileURL,
                            currentPageIndex: `$currentPageIndex,
                            totalPages: `$pages, // Note: we can just use `pages` array size to report total pages to the Scrubber
                            isVerticalScroll: isVerticalScroll,
                            isMangaMode: isMangaMode,
                            onSingleTap: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isToolbarVisible.toggle()
                                }
                            }
                        )
                        .colorMultiply(.white)
                        .colorInvertIfDark(theme: EBookPreferences.shared.activeTheme)
                    }
"@

$targetPDFStruct = '(?s)// MARK: - Standard PDF Component\r?\nstruct PDFKitView: UIViewRepresentable \{.*?\r?\n\}\r?\n'
$replacementPDFStruct = @"
// MARK: - Standard PDF Component
struct PDFKitView: UIViewRepresentable {
    let url: URL
    @Binding var currentPageIndex: Int
    @Binding var totalPages: [URL] // Hack to report Total Pages bounds out to ReaderView
    let isVerticalScroll: Bool
    let isMangaMode: Bool
    let onSingleTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage // Zero-latency rendering
        pdfView.displayDirection = isVerticalScroll ? .vertical : .horizontal
        pdfView.displaysPageBreaks = false
        
        // Tap Gesture to intercept taps before they get absorbed
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        pdfView.addGestureRecognizer(tap)
        
        // Page tracking Notification
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        
        if let document = PDFDocument(url: url) {
            pdfView.document = document
            DispatchQueue.main.async {
                self.totalPages = Array(repeating: url, count: document.pageCount)
            }
        }
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        pdfView.displayDirection = isVerticalScroll ? .vertical : .horizontal
        pdfView.displaysRTL = isMangaMode
        
        // Scrubbing sync: if SwiftUI changes currentPageIndex via scrubber, navigate!
        if let doc = pdfView.document,
           currentPageIndex >= 0 && currentPageIndex < doc.pageCount,
           let currentVisible = pdfView.currentPage,
           doc.index(for: currentVisible) != currentPageIndex {
            if let targetPage = doc.page(at: currentPageIndex) {
                pdfView.go(to: targetPage)
            }
        }
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PDFKitView
        
        init(_ parent: PDFKitView) {
            self.parent = parent
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            parent.onSingleTap()
        }
        
        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let currentPage = pdfView.currentPage,
                  let document = pdfView.document else { return }
            
            let index = document.index(for: currentPage)
            if index != parent.currentPageIndex {
                DispatchQueue.main.async {
                    self.parent.currentPageIndex = index
                }
            }
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true // Allow internal scrolls while still listening for taps
        }
    }
}

extension View {
    @ViewBuilder func colorInvertIfDark(theme: EBookTheme) -> some View {
        if theme == .dark || theme == .obsidian {
            self.colorInvert().hueRotation(.degrees(180))
        } else {
            self
        }
    }
}

"@

$content = [regex]::Replace($content, $targetPDFCall, $replacementPDFCall)
$content = [regex]::Replace($content, $targetPDFStruct, $replacementPDFStruct)

Set-Content -Path $file -Value $content -Encoding UTF8

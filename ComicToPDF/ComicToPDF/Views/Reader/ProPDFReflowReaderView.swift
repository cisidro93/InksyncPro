import SwiftUI
import PDFKit
import WebKit

struct ProPDFReflowReaderView: View {
    let pdf: ConvertedPDF
    let pdfDocument: PDFDocument?
    @Binding var currentPageIndex: Int
    var isChromeVisible: Bool = true
    var onDismiss: () -> Void
    var onToggleReflow: (() -> Void)? = nil
    var onCenterTap: (() -> Void)? = nil

    @State private var reflowHTMLURL: URL? = nil
    @State private var isCompilingReflow = true
    @State private var webViewRef: WKWebView? = nil
    @State private var chapterPage: Int = 0
    @State private var chapterTotalPages: Int = 1
    @State private var hasAnchoredInitialPage = false
    @ObservedObject private var prefs = EBookPreferences.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            AmbientReaderBackground(theme: prefs.activeTheme)
                .ignoresSafeArea()

            if isCompilingReflow {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(.inkGreen)
                    Text("Compiling Reflowable Layout...")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let htmlURL = reflowHTMLURL {
                EBookPageCurlReader(
                    spineItem: EBookMetadata.SpineItem(
                        id: htmlURL.lastPathComponent,
                        href: htmlURL.lastPathComponent,
                        label: pdf.name
                    ),
                    unzipDir: htmlURL.deletingLastPathComponent(),
                    prefs: prefs,
                    colorScheme: colorScheme,
                    currentPage: $chapterPage,
                    initialPage: 0,
                    totalPages: $chapterTotalPages,
                    onNext: {
                        syncCurrentPDFPageFromReflow()
                    },
                    onPrev: {
                        syncCurrentPDFPageFromReflow()
                    },
                    onCenterTap: {
                        onCenterTap?()
                    },
                    onPageTurn: {
                        syncCurrentPDFPageFromReflow()
                    },
                    pdfID: pdf.id,
                    initialScrollFraction: 0.0,
                    onScrollFractionChanged: { fraction in
                        syncCurrentPDFPageFromReflow()
                    },
                    webViewRef: $webViewRef
                )
                .onChange(of: webViewRef) { _, newWebView in
                    if newWebView != nil && !hasAnchoredInitialPage {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                            scrollToCurrentPDFPage()
                        }
                    }
                }
                .onAppear {
                    if webViewRef != nil && !hasAnchoredInitialPage {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                            scrollToCurrentPDFPage()
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Reflow Layout Unavailable")
                        .font(.system(size: 16, weight: .bold))
                    Text("This document does not contain extractable text blocks.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await compileReflowLayout()
        }
    }

    private func scrollToCurrentPDFPage(attempt: Int = 1) {
        guard let webView = webViewRef else { return }
        let targetPageNumber = currentPageIndex + 1
        let js = """
        (function() {
            var el = document.getElementById('page-\(targetPageNumber)');
            if (!el) {
                var markers = document.querySelectorAll('.pdf-page-marker');
                if (markers.length > 0) {
                    var idx = Math.min(markers.length - 1, Math.max(0, \(currentPageIndex)));
                    el = markers[idx];
                }
            }
            if (!el) return -1;
            if (typeof computeMetrics === 'function' && (_totalPages <= 1 || typeof _totalPages === 'undefined')) {
                computeMetrics();
            }
            if (typeof _totalPages === 'undefined' || _totalPages <= 1) {
                return 0; // metrics still compiling, need retry
            }
            var rect = el.getBoundingClientRect();
            var vp = document.getElementById('inksync-viewport') || document.body;
            var vpRect = vp ? vp.getBoundingClientRect() : { left: 0 };
            var offsetLeft = (rect.left - vpRect.left);
            var pageStep = (typeof getPageStep === 'function') ? getPageStep() : window.innerWidth;
            var colWidth = (typeof _isMultiCol !== 'undefined' && _isMultiCol) ? (pageStep / 2) : pageStep;
            if (colWidth > 0 && typeof goToPage === 'function') {
                var targetPage = Math.max(0, Math.min(Math.floor(offsetLeft / colWidth), _totalPages - 1));
                goToPage(targetPage, false);
                return 1; // success
            }
            return -1;
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            let code = result as? Int ?? -1
            if code == 1 {
                self.hasAnchoredInitialPage = true
            } else if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.scrollToCurrentPDFPage(attempt: attempt + 1)
                }
            } else {
                self.hasAnchoredInitialPage = true
            }
        }
    }

    private func syncCurrentPDFPageFromReflow() {
        guard let webView = webViewRef else { return }
        let js = """
        (function() {
            var markers = document.querySelectorAll('.pdf-page-marker');
            if (!markers || markers.length === 0) return -1;
            var winW = window.innerWidth || 390;
            var bestPage = -1;
            for (var i = 0; i < markers.length; i++) {
                var m = markers[i];
                var r = m.getBoundingClientRect();
                if (r.left < winW && r.right > 0) {
                    var p = parseInt(m.getAttribute('data-page') || '0', 10);
                    if (p > 0) {
                        bestPage = p - 1;
                    }
                }
            }
            if (bestPage < 0) {
                for (var j = markers.length - 1; j >= 0; j--) {
                    var mr = markers[j].getBoundingClientRect();
                    if (mr.left <= winW) {
                        var pj = parseInt(markers[j].getAttribute('data-page') || '0', 10);
                        if (pj > 0) {
                            bestPage = pj - 1;
                            break;
                        }
                    }
                }
            }
            return bestPage;
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            if let pageIdx = result as? Int, pageIdx >= 0 {
                Task { @MainActor in
                    self.currentPageIndex = pageIdx
                }
            }
        }
    }

    private func compileReflowLayout() async {
        guard let doc = pdfDocument else {
            isCompilingReflow = false
            return
        }

        let pdfUUID = pdf.id.uuidString

        let fileManager = FileManager.default
        if let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let cachedURL = cacheDir.appendingPathComponent("ReflowPDF/\(pdfUUID)/reflow.html")
            if fileManager.fileExists(atPath: cachedURL.path) {
                self.reflowHTMLURL = cachedURL
                self.isCompilingReflow = false
                return
            }
        }

        let blocks = await PDFSpatialParser.shared.parseDocument(doc)

        // Only extract images for pages that lack digital text blocks
        let textPages = Set(blocks.map { $0.pageIndex })
        let nonTextPages = Set(0..<doc.pageCount).subtracting(textPages)
        let images = await PDFImageExtractor.shared.extractImages(from: doc, pdfUUID: pdfUUID, nonTextPages: nonTextPages)

        let compiledURL = await ReflowDOMSynthesizer.shared.synthesizeHTML(
            pdfUUID: pdfUUID,
            documentTitle: pdf.name,
            blocks: blocks,
            images: images
        )

        self.reflowHTMLURL = compiledURL
        self.isCompilingReflow = false
    }
}

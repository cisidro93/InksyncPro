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
                    pdfID: pdf.id,
                    initialScrollFraction: 0.0,
                    onScrollFractionChanged: { fraction in
                        syncCurrentPDFPageFromReflow()
                    },
                    onPageTurn: {
                        syncCurrentPDFPageFromReflow()
                    },
                    webViewRef: $webViewRef
                )
                .onChange(of: webViewRef) { _, newWebView in
                    if newWebView != nil && !hasAnchoredInitialPage {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            scrollToCurrentPDFPage()
                            hasAnchoredInitialPage = true
                        }
                    }
                }
                .onAppear {
                    if webViewRef != nil && !hasAnchoredInitialPage {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            scrollToCurrentPDFPage()
                            hasAnchoredInitialPage = true
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

            // Top Floating Mode Toggle Pill & Status
            if let toggle = onToggleReflow, isChromeVisible {
                HStack(spacing: 8) {
                    Button(action: {
                        HapticEngine.light()
                        toggle()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 12, weight: .bold))
                            Text("Vector View")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.72).background(.ultraThinMaterial))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    }

                    Spacer()

                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.inkGreen)
                            .frame(width: 7, height: 7)
                        Text("Reflow Mode")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.65).background(.ultraThinMaterial))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.inkGreen.opacity(0.4), lineWidth: 0.8))
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(20)
            }
        }
        .task {
            await compileReflowLayout()
        }
    }

    private func scrollToCurrentPDFPage() {
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
            if (el) {
                var rect = el.getBoundingClientRect();
                var vp = document.getElementById('inksync-viewport') || document.body;
                var vpRect = vp ? vp.getBoundingClientRect() : { left: 0 };
                var offsetLeft = (rect.left - vpRect.left);
                var pageStep = (typeof getPageStep === 'function') ? getPageStep() : window.innerWidth;
                var colWidth = (typeof _isMultiCol !== 'undefined' && _isMultiCol) ? (pageStep / 2) : pageStep;
                if (colWidth > 0 && typeof goToPage === 'function') {
                    var targetPage = Math.max(0, Math.min(Math.floor(offsetLeft / colWidth), (typeof _totalPages !== 'undefined' ? _totalPages : 1) - 1));
                    goToPage(targetPage, false);
                }
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
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

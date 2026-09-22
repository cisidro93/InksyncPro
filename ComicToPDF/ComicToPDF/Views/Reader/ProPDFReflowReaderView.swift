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

    // Target tracking & anchoring safety
    @State private var targetPDFPageIndex: Int
    @State private var hasAnchoredInitialPage = false
    @State private var isAnchoringInProgress = false
    @State private var lastSyncedPDFPageIndex: Int? = nil
    @State private var reanchorTask: Task<Void, Never>? = nil

    // Reflow compilation & webview state
    @State private var reflowHTMLURL: URL? = nil
    @State private var isCompilingReflow = true
    @State private var webViewRef: WKWebView? = nil
    @State private var chapterPage: Int = 0
    @State private var chapterTotalPages: Int = 1

    @ObservedObject private var prefs = EBookPreferences.shared
    @Environment(\.colorScheme) private var colorScheme

    init(
        pdf: ConvertedPDF,
        pdfDocument: PDFDocument?,
        currentPageIndex: Binding<Int>,
        isChromeVisible: Bool = true,
        onDismiss: @escaping () -> Void,
        onToggleReflow: (() -> Void)? = nil,
        onCenterTap: (() -> Void)? = nil
    ) {
        self.pdf = pdf
        self.pdfDocument = pdfDocument
        self._currentPageIndex = currentPageIndex
        self.isChromeVisible = isChromeVisible
        self.onDismiss = onDismiss
        self.onToggleReflow = onToggleReflow
        self.onCenterTap = onCenterTap
        self._targetPDFPageIndex = State(initialValue: currentPageIndex.wrappedValue)
    }

    private var totalPDFPages: Int {
        pdfDocument?.pageCount ?? max(1, targetPDFPageIndex + 1)
    }

    private var initialFraction: Double {
        totalPDFPages > 1 ? min(1.0, max(0.0, Double(targetPDFPageIndex) / Double(totalPDFPages - 1))) : 0.0
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .center) {
                AmbientReaderBackground(theme: prefs.activeTheme)
                    .ignoresSafeArea()

                if isCompilingReflow {
                    compilingOverlay
                } else if let htmlURL = reflowHTMLURL {
                    ZStack {
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
                            initialScrollFraction: initialFraction,
                            onScrollFractionChanged: { _ in
                                syncCurrentPDFPageFromReflow()
                            },
                            webViewRef: $webViewRef
                        )
                        .opacity(hasAnchoredInitialPage ? 1.0 : 0.0)
                        .animation(.easeInOut(duration: 0.18), value: hasAnchoredInitialPage)

                        if !hasAnchoredInitialPage {
                            ProgressView()
                                .scaleEffect(1.1)
                                .tint(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.8))
                        }
                    }
                    .onChange(of: webViewRef) { _, newWebView in
                        if newWebView != nil && !hasAnchoredInitialPage {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                scrollToTargetPDFPage(pageIndex: targetPDFPageIndex)
                            }
                        }
                    }
                    .onAppear {
                        if webViewRef != nil && !hasAnchoredInitialPage {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                scrollToTargetPDFPage(pageIndex: targetPDFPageIndex)
                            }
                        }
                    }
                    .onChange(of: currentPageIndex) { _, newIndex in
                        // If currentPageIndex changed from outside (e.g. Scrubber bar, TOC, Bookmarks),
                        // scroll to that new target. Avoid echoing when changed internally via syncCurrentPDFPageFromReflow.
                        if hasAnchoredInitialPage && !isAnchoringInProgress && newIndex != lastSyncedPDFPageIndex {
                            scrollToTargetPDFPage(pageIndex: newIndex)
                        }
                    }
                } else {
                    unavailableOverlay
                }
            }
            .onChange(of: size) { oldSize, newSize in
                guard newSize.width > 50 && newSize.height > 50 else { return }
                guard oldSize != .zero && (abs(oldSize.width - newSize.width) > 5 || abs(oldSize.height - newSize.height) > 5) else { return }
                handleOrientationOrBoundsChange(newSize: newSize)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                handleOrientationOrBoundsChange(newSize: size)
            }
        }
        .task {
            await compileReflowLayout()
        }
        .onDisappear {
            reanchorTask?.cancel()
            reanchorTask = nil
        }
    }

    private func scrollToTargetPDFPage(pageIndex: Int, attempt: Int = 1, isOrientationChange: Bool = false) {
        guard let webView = webViewRef else {
            if attempt < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    self.scrollToTargetPDFPage(pageIndex: pageIndex, attempt: attempt + 1, isOrientationChange: isOrientationChange)
                }
            }
            return
        }

        isAnchoringInProgress = true
        let targetPageNumber = pageIndex + 1

        let js = """
        (function() {
            var targetNum = \(targetPageNumber);
            if (typeof computeMetrics === 'function' && (typeof _totalPages === 'undefined' || _totalPages <= 1)) {
                computeMetrics();
            }
            if (typeof _totalPages === 'undefined' || _totalPages <= 0) {
                return -2; // Metrics not ready yet, retry
            }

            var el = document.getElementById('page-' + targetNum);
            if (!el) {
                el = document.querySelector('[data-page="' + targetNum + '"]') ||
                     document.querySelector('[data-pdf-page="' + targetNum + '"]');
            }
            if (!el) {
                var markers = document.querySelectorAll('.pdf-page-marker');
                for (var i = markers.length - 1; i >= 0; i--) {
                    var p = parseInt(markers[i].getAttribute('data-page') || '0', 10);
                    if (p <= targetNum) {
                        el = markers[i];
                        break;
                    }
                }
                if (!el && markers.length > 0) {
                    el = markers[0];
                }
            }
            if (!el) return -1;

            var rect = el.getBoundingClientRect();
            var vp = document.getElementById('inksync-viewport') || document.body;
            var vpRect = vp ? vp.getBoundingClientRect() : { left: 0 };
            var offsetLeft = (rect.left - vpRect.left);
            var pageStep = (typeof getPageStep === 'function') ? getPageStep() : (window.innerWidth || 390);
            var colWidth = (typeof _isMultiCol !== 'undefined' && _isMultiCol) ? (pageStep / 2) : pageStep;

            if (colWidth > 0 && typeof goToPage === 'function') {
                var targetPage = Math.max(0, Math.min(Math.floor(offsetLeft / colWidth), _totalPages - 1));
                goToPage(targetPage, false);
                return targetPage;
            }
            return -1;
        })();
        """

        webView.evaluateJavaScript(js) { [self] result, _ in
            let code = (result as? Int) ?? -1
            if code >= 0 {
                self.chapterPage = code
                self.hasAnchoredInitialPage = true
                self.isAnchoringInProgress = false
                self.lastSyncedPDFPageIndex = pageIndex
                self.currentPageIndex = pageIndex
                if isOrientationChange {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.syncCurrentPDFPageFromReflow()
                    }
                }
            } else if (code == -2 || code == -1) && attempt < 8 {
                let delay = attempt < 3 ? 0.12 : 0.25
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.scrollToTargetPDFPage(pageIndex: pageIndex, attempt: attempt + 1, isOrientationChange: isOrientationChange)
                }
            } else {
                self.hasAnchoredInitialPage = true
                self.isAnchoringInProgress = false
            }
        }
    }

    private func syncCurrentPDFPageFromReflow() {
        guard hasAnchoredInitialPage && !isAnchoringInProgress else { return }
        guard let webView = webViewRef else { return }

        let js = """
        (function() {
            var markers = document.querySelectorAll('.pdf-page-marker');
            if (!markers || markers.length === 0) return -1;
            var winW = window.innerWidth || 390;
            var bestPage = -1;
            var maxVisibleWidth = 0;

            for (var i = 0; i < markers.length; i++) {
                var m = markers[i];
                var r = m.getBoundingClientRect();
                var visibleLeft = Math.max(0, r.left);
                var visibleRight = Math.min(winW, r.right);
                var visibleWidth = visibleRight - visibleLeft;
                if (visibleWidth > maxVisibleWidth) {
                    var p = parseInt(m.getAttribute('data-page') || '0', 10);
                    if (p > 0) {
                        maxVisibleWidth = visibleWidth;
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
                    self.lastSyncedPDFPageIndex = pageIdx
                    self.currentPageIndex = pageIdx
                }
            }
        }
    }

    private func handleOrientationOrBoundsChange(newSize: CGSize) {
        guard hasAnchoredInitialPage && !isCompilingReflow else { return }
        guard let webView = webViewRef else { return }

        reanchorTask?.cancel()
        reanchorTask = Task { @MainActor in
            let currentTarget = self.currentPageIndex
            self.isAnchoringInProgress = true

            // Brief yield for UIKit to commit layout geometry
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }

            // Pass 1: Recalculate metrics immediately for the new bounds
            _ = try? await webView.evaluateJavaScript("if(typeof computeMetrics === 'function') { computeMetrics(); }")
            guard !Task.isCancelled else { return }

            self.scrollToTargetPDFPage(pageIndex: currentTarget, isOrientationChange: true)

            // Pass 2: Settle verification after WebKit layout finishes animating
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            self.scrollToTargetPDFPage(pageIndex: currentTarget, isOrientationChange: true)
        }
    }

    @ViewBuilder
    private var compilingOverlay: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.inkGreen.opacity(0.15))
                    .frame(width: 72, height: 72)

                ProgressView()
                    .scaleEffect(1.3)
                    .tint(.inkGreen)
            }

            VStack(spacing: 6) {
                Text("Reflowing Document")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))

                Text("Synthesizing spatial typography & columns...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme).opacity(0.7))
            }

            if let onToggle = onToggleReflow {
                Button(action: onToggle) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.top, 8)
            }
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var unavailableOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.textSecondary)

            VStack(spacing: 6) {
                Text("Reflow Layout Unavailable")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(prefs.activeTheme.foreground(colorScheme: colorScheme))

                Text("This document does not contain extractable text blocks.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if let onToggle = onToggleReflow {
                Button(action: onToggle) {
                    Text("Return to Standard Reader")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.inkGreen, in: Capsule())
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

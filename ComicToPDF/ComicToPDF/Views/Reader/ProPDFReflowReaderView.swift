import SwiftUI
@preconcurrency import PDFKit
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
    @State private var syncDebounceTask: Task<Void, Never>? = nil

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
        self._lastSyncedPDFPageIndex = State(initialValue: currentPageIndex.wrappedValue)

        let isClutterFiltered = EBookPreferences.shared.pdfReflowSmartClutterRemoval
        let isCached = ReflowCompilationCoordinator.shared.hasCachedReflow(pdfUUID: pdf.id.uuidString, isClutterFiltered: isClutterFiltered)
        if isCached, let cachedURL = ReflowCompilationCoordinator.shared.cachedReflowURL(pdfUUID: pdf.id.uuidString, isClutterFiltered: isClutterFiltered) {
            self._reflowHTMLURL = State(initialValue: cachedURL)
            self._isCompilingReflow = State(initialValue: false)
        } else {
            self._reflowHTMLURL = State(initialValue: nil)
            self._isCompilingReflow = State(initialValue: true)
        }
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
                        pageCurlReaderView(htmlURL: htmlURL)

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
                        targetPDFPageIndex = currentPageIndex
                        lastSyncedPDFPageIndex = currentPageIndex
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
                            targetPDFPageIndex = newIndex
                            lastSyncedPDFPageIndex = newIndex
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
            .onChange(of: prefs.pdfReflowSmartClutterRemoval) { _, _ in
                Task { @MainActor in
                    self.isCompilingReflow = true
                    self.hasAnchoredInitialPage = false
                    await compileReflowLayout()
                }
            }
        }
        .task {
            await compileReflowLayout()
        }
        .onDisappear {
            reanchorTask?.cancel()
            reanchorTask = nil
            syncDebounceTask?.cancel()
            syncDebounceTask = nil
        }
        .readerKeyboardShortcuts(
            onNextPage: {
                NotificationCenter.default.post(name: NSNotification.Name("ReaderAdvancePageForward"), object: nil)
            },
            onPreviousPage: {
                NotificationCenter.default.post(name: NSNotification.Name("ReaderAdvancePageBackward"), object: nil)
            },
            onDismiss: {
                onDismiss()
            }
        )
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
            var currentShift = (typeof _currentShift !== 'undefined') ? _currentShift : 0;
            var absLeft = vp ? (rect.left - vp.getBoundingClientRect().left) : (rect.left + currentShift);
            var pageStep = (typeof getPageStep === 'function') ? getPageStep() : (window.innerWidth || 390);
            var isMulti = (typeof _isMultiCol !== 'undefined') ? _isMultiCol : false;
            var colStride = isMulti ? (pageStep / 2) : pageStep;

            if (colStride > 0 && typeof goToPage === 'function') {
                var targetPage = Math.max(0, Math.min(Math.floor(absLeft / colStride), _totalPages - 1));
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
                let delay = attempt < 3 ? 0.06 : 0.14
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
            var winW = window.innerWidth || 390;
            var winH = window.innerHeight || 844;
            if (winW <= 0 || winH <= 0) return -1;

            var isMulti = (typeof _isMultiCol !== 'undefined') ? _isMultiCol : false;

            function extractPageNumber(node) {
                if (!node) return -1;
                var curr = node;
                while (curr && curr !== document.body && curr !== document.documentElement) {
                    var val = curr.getAttribute ? (curr.getAttribute('data-pdf-page') || curr.getAttribute('data-page')) : null;
                    if (val) {
                        var parsed = parseInt(val, 10);
                        if (!isNaN(parsed) && parsed > 0) return parsed - 1;
                    }
                    curr = curr.parentElement;
                }
                return -1;
            }

            // Strategy 1: Multi-point vertical sample along reading column center
            // In single column: sample at x = 0.5 * winW.
            // In dual column: sample left column first at x = 0.25 * winW, then right column at x = 0.75 * winW.
            var sampleXCoordinates = isMulti ? [winW * 0.25, winW * 0.75] : [winW * 0.5];
            var sampleYFractions = [0.25, 0.40, 0.55, 0.70, 0.15, 0.85];

            for (var xIdx = 0; xIdx < sampleXCoordinates.length; xIdx++) {
                var sx = sampleXCoordinates[xIdx];
                for (var yIdx = 0; yIdx < sampleYFractions.length; yIdx++) {
                    var sy = winH * sampleYFractions[yIdx];
                    var el = document.elementFromPoint(sx, sy);
                    var page = extractPageNumber(el);
                    if (page >= 0) return page;
                }
            }

            // Strategy 2: Scan elements with data-pdf-page for intersection with screen viewport
            var pageElements = document.querySelectorAll('[data-pdf-page]');
            for (var i = 0; i < pageElements.length; i++) {
                var el = pageElements[i];
                var r = el.getBoundingClientRect();
                if (r.right > 16 && r.left < (winW - 16) && r.bottom > 16 && r.top < (winH - 16)) {
                    var val = el.getAttribute('data-pdf-page');
                    var parsed = parseInt(val, 10);
                    if (!isNaN(parsed) && parsed > 0) return parsed - 1;
                }
            }

            // Strategy 3: Check for large element spanning across column
            for (var j = 0; j < pageElements.length; j++) {
                var el = pageElements[j];
                var r = el.getBoundingClientRect();
                if (r.left <= 16 && r.right >= (winW - 16) && r.bottom > 16 && r.top < (winH - 16)) {
                    var val = el.getAttribute('data-pdf-page');
                    var parsed = parseInt(val, 10);
                    if (!isNaN(parsed) && parsed > 0) return parsed - 1;
                }
            }

            // Fallback: Return -1 to safely preserve current page without wild jumps
            return -1;
        })();
        """

        webView.evaluateJavaScript(js) { [self] result, _ in
            if let pageIdx = result as? Int, pageIdx >= 0 {
                Task { @MainActor in
                    guard self.hasAnchoredInitialPage && !self.isAnchoringInProgress else { return }
                    if self.currentPageIndex != pageIdx {
                        self.lastSyncedPDFPageIndex = pageIdx
                        self.currentPageIndex = pageIdx
                    }
                }
            }
        }
    }

    private func debouncedSyncCurrentPDFPage() {
        guard hasAnchoredInitialPage && !isAnchoringInProgress else { return }
        syncDebounceTask?.cancel()
        syncDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self.syncCurrentPDFPageFromReflow()
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
    private func pageCurlReaderView(htmlURL: URL) -> some View {
        let spineItem = EBookMetadata.SpineItem(
            id: htmlURL.lastPathComponent,
            href: htmlURL.lastPathComponent,
            label: pdf.name
        )
        let unzipDir = htmlURL.deletingLastPathComponent()
        let targetAnchor = "page-\(targetPDFPageIndex + 1)"

        EBookPageCurlReader(
            spineItem: spineItem,
            unzipDir: unzipDir,
            prefs: prefs,
            colorScheme: colorScheme,
            currentPage: $chapterPage,
            initialPage: 0,
            totalPages: $chapterTotalPages,
            onNext: { debouncedSyncCurrentPDFPage() },
            onPrev: { debouncedSyncCurrentPDFPage() },
            onCenterTap: { onCenterTap?() },
            onPageTurn: { debouncedSyncCurrentPDFPage() },
            pdfID: pdf.id,
            initialScrollFraction: 0.0,
            onScrollFractionChanged: { _ in debouncedSyncCurrentPDFPage() },
            webViewRef: $webViewRef,
            targetAnchor: targetAnchor
        )
        .opacity(hasAnchoredInitialPage ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.18), value: hasAnchoredInitialPage)
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

        let isClutterFiltered = prefs.pdfReflowSmartClutterRemoval
        let compiledURL = await ReflowCompilationCoordinator.shared.compileOrFetchReflow(
            document: doc,
            pdfUUID: pdf.id.uuidString,
            documentTitle: pdf.name,
            isClutterFiltered: isClutterFiltered
        )

        self.reflowHTMLURL = compiledURL
        self.isCompilingReflow = false
    }
}

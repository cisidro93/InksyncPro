import SwiftUI
import PDFKit
import UIKit

/// Ground-Up Rebuilt Pro Native PDF Reader Engine
/// Pure Apple PDFKit implementation with zero filters, zero overlays,
/// hardware-accelerated vector rendering, and streamlined glassmorphic chrome.
struct ProPDFReaderEngine: View {
    let pdf: ConvertedPDF
    var onDismiss: () -> Void

    @State private var pdfDocument: PDFDocument? = nil
    @State private var currentPageIndex: Int = 0
    @State private var totalPages: Int = 1
    @State private var isDocumentLoading = true
    @State private var chromeVisible = true
    @State private var pdfViewReference: PDFView? = nil

    // Sheets
    @State private var showingPageManager = false
    @State private var showingInspector = false
    @State private var showingOutline = false

    // Security scoped URL tracking
    @State private var accessedSecurityScopedURL: URL? = nil

    var body: some View {
        ZStack {
            // Ambient Dark Reader Canvas
            Color(hex: "#0c0d14")
                .ignoresSafeArea()

            if isDocumentLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.3)
                        .tint(.inkGreen)
                    Text("Loading PDF...")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.8))

                    Button(action: onDismiss) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .bold))
                            Text("Back to Library")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .padding(.top, 8)
                }
            } else if let doc = pdfDocument {
                // Native Apple PDF Canvas
                NativePDFViewRepresentable(
                    document: doc,
                    currentPageIndex: $currentPageIndex,
                    pdfViewRef: $pdfViewReference,
                    onPageChanged: { newIndex in
                        currentPageIndex = newIndex
                        saveReadingProgress()
                    },
                    onTapCenter: {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            chromeVisible.toggle()
                        }
                    }
                )
                .ignoresSafeArea()

                // Top Navigation Chrome
                if chromeVisible {
                    VStack {
                        topNavigationBar
                            .transition(.move(edge: .top).combined(with: .opacity))
                        Spacer()
                    }
                }

                // Bottom Navigation Scrubber Chrome
                if chromeVisible {
                    VStack {
                        Spacer()
                        bottomScrubberBar
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            } else {
                // Error / Empty State
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundColor(.yellow)
                    Text("Unable to open PDF document.")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)

                    Button(action: onDismiss) {
                        Text("Return to Library")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.inkGreen, in: Capsule())
                    }
                }
            }
        }
        .task {
            await loadPDFDocument()
        }
        .onDisappear {
            saveReadingProgress()
            accessedSecurityScopedURL?.stopAccessingSecurityScopedResource()
            accessedSecurityScopedURL = nil
        }
        .sheet(isPresented: $showingPageManager) {
            PDFPageManagerGridView(
                pdf: pdf,
                pdfDocument: pdfDocument,
                onJumpToPage: { pageIdx in
                    jumpToPage(pageIdx)
                },
                onDismiss: {
                    showingPageManager = false
                }
            )
        }
        .sheet(isPresented: $showingInspector) {
            ProDocumentInspectorView(
                pdf: pdf,
                pdfDocument: pdfDocument,
                currentPageIndex: currentPageIndex,
                onJumpToPage: { pageIdx in
                    jumpToPage(pageIdx)
                },
                onDismiss: {
                    showingInspector = false
                }
            )
        }
    }

    // MARK: - Top Navigation Bar
    private var topNavigationBar: some View {
        HStack(spacing: 12) {
            Button(action: {
                HapticEngine.selection()
                saveReadingProgress()
                onDismiss()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                    Text("Library")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            }

            Spacer()

            Text(pdf.name)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            // Page Manager Grid Button
            Button(action: {
                HapticEngine.light()
                showingPageManager = true
            }) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }

            // Document Inspector / Info Button
            Button(action: {
                HapticEngine.light()
                showingInspector = true
            }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - Bottom Scrubber Bar
    private var bottomScrubberBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                // Prev Page Button
                Button(action: {
                    jumpToPage(currentPageIndex - 1)
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(currentPageIndex > 0 ? .white : .white.opacity(0.3))
                }
                .disabled(currentPageIndex <= 0)

                // Page Scrubber Slider
                Slider(
                    value: Binding<Double>(
                        get: { Double(currentPageIndex) },
                        set: { jumpToPage(Int($0)) }
                    ),
                    in: 0...Double(max(0, totalPages - 1)),
                    step: 1.0
                )
                .tint(.inkGreen)

                // Next Page Button
                Button(action: {
                    jumpToPage(currentPageIndex + 1)
                }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(currentPageIndex < totalPages - 1 ? .white : .white.opacity(0.3))
                }
                .disabled(currentPageIndex >= totalPages - 1)
            }

            // Page Counter Pill
            Text("Page \(currentPageIndex + 1) of \(totalPages)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.85))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    // MARK: - Document Navigation & Persistence
    private func jumpToPage(_ pageIndex: Int) {
        guard let doc = pdfDocument else { return }
        let target = max(0, min(pageIndex, doc.pageCount - 1))
        if target != currentPageIndex {
            HapticEngine.selection()
            currentPageIndex = target
            if let page = doc.page(at: target) {
                pdfViewReference?.go(to: page)
            }
            saveReadingProgress()
        }
    }

    private func saveReadingProgress() {
        guard totalPages > 0 else { return }
        let progress = Double(currentPageIndex) / Double(max(1, totalPages - 1))
        Task { @MainActor in
            ReaderProgressTracker.shared.updateProgress(
                for: pdf.id,
                pageIndex: currentPageIndex,
                totalPages: totalPages,
                progress: progress
            )
        }
    }

    // MARK: - Document Loading
    private func loadPDFDocument() async {
        let sourcePDF = self.pdf
        
        let doc = await Task.detached(priority: .userInitiated) { () -> (PDFDocument?, URL?) in
            var accessedURL: URL? = nil
            let targetURL: URL
            
            if case .linked(let bm) = sourcePDF.sourceMode,
               let url = try? BookmarkResolver.shared.resolve(bm) {
                let didAccess = url.startAccessingSecurityScopedResource()
                targetURL = url
                if didAccess { accessedURL = url }
            } else {
                let sandboxURL = LibraryFileRecord.resolveSandboxURL(sourcePDF.url.absoluteString)
                let didAccess = sandboxURL.startAccessingSecurityScopedResource()
                targetURL = sandboxURL
                if didAccess { accessedURL = sandboxURL }
            }
            
            var loaded = PDFDocument(url: targetURL)
            if loaded == nil && targetURL != sourcePDF.url {
                let didAccessSource = sourcePDF.url.startAccessingSecurityScopedResource()
                if didAccessSource && accessedURL == nil { accessedURL = sourcePDF.url }
                loaded = PDFDocument(url: sourcePDF.url)
            }
            
            return (loaded, accessedURL)
        }.value

        await MainActor.run {
            if let accessed = doc.1 {
                self.accessedSecurityScopedURL = accessed
            }
            if let loadedDoc = doc.0 {
                self.pdfDocument = loadedDoc
                self.totalPages = max(1, loadedDoc.pageCount)
                let savedIndex = ReaderProgressTracker.shared.progress(for: sourcePDF.id)?.currentPageIndex ?? 0
                self.currentPageIndex = max(0, min(savedIndex, loadedDoc.pageCount - 1))
                self.isDocumentLoading = false
            } else {
                self.isDocumentLoading = false
            }
        }
    }
}

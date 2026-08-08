import SwiftUI
import PDFKit
import WebKit

struct ProPDFReflowReaderView: View {
    let pdf: ConvertedPDF
    let pdfDocument: PDFDocument?
    @Binding var currentPageIndex: Int
    var onDismiss: () -> Void

    @State private var reflowHTMLURL: URL? = nil
    @State private var isCompilingReflow = true
    @State private var webViewRef: WKWebView? = nil
    @State private var chapterPage: Int = 0
    @State private var chapterTotalPages: Int = 1
    @ObservedObject private var prefs = EBookPreferences.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
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
                    initialPage: currentPageIndex,
                    totalPages: $chapterTotalPages,
                    onNext: {},
                    onPrev: {},
                    onCenterTap: {},
                    pdfID: pdf.id,
                    initialScrollFraction: 0.0,
                    onScrollFractionChanged: { fraction in
                        if chapterTotalPages > 1 {
                            let target = Int((fraction * Double(chapterTotalPages - 1)).rounded())
                            currentPageIndex = max(0, min(target, (pdfDocument?.pageCount ?? 1) - 1))
                        }
                    },
                    webViewRef: $webViewRef
                )
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
            }
        }
        .task {
            await compileReflowLayout()
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
        let images = await PDFImageExtractor.shared.extractImages(from: doc, pdfUUID: pdfUUID)

        let compiledURL = await ReflowDOMSynthesizer.shared.synthesizeHTML(
            pdfUUID: pdfUUID,
            documentTitle: pdf.name,
            blocks: blocks,
            images: images
        )

        await MainActor.run {
            self.reflowHTMLURL = compiledURL
            self.isCompilingReflow = false
        }
    }
}

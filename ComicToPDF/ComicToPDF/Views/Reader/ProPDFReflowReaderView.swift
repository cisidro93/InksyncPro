import SwiftUI
import PDFKit
import WebKit

struct ProPDFReflowReaderView: View {
    let pdf: ConvertedPDF
    let pdfDocument: PDFDocument?
    @Binding var currentPageIndex: Int
    var onDismiss: () -> Void
    var onToggleReflow: (() -> Void)? = nil

    @State private var reflowHTMLURL: URL? = nil
    @State private var isCompilingReflow = true
    @State private var webViewRef: WKWebView? = nil
    @State private var chapterPage: Int = 0
    @State private var chapterTotalPages: Int = 1
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Top Floating Mode Toggle Pill
            if let toggle = onToggleReflow {
                Button(action: {
                    HapticEngine.light()
                    toggle()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 12, weight: .bold))
                        Text("Vector View")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.65))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                }
                .padding(.leading, 16)
                .padding(.top, 14)
                .zIndex(20)
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

        let blocks = PDFSpatialParser.shared.parseDocument(doc)
        let images = PDFImageExtractor.shared.extractImages(from: doc, pdfUUID: pdfUUID)

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

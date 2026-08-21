import Foundation
import UIKit
import PDFKit
import SwiftUI

/// Comprehensive Real-Time Diagnostic Engine for InksyncPro's ProPDFReaderEngine
@MainActor
final class PDFDiagnosticEngine: ObservableObject {
    static let shared = PDFDiagnosticEngine()

    @Published var isHUDVisible: Bool = false
    @Published var lastReport: String = ""
    @Published var directRenderImage: UIImage? = nil
    @Published var lastLoggedTimestamp: Date = Date()

    private init() {}

    /// Generates a comprehensive multi-point diagnostic inspection of the PDF document and view hierarchy.
    func inspect(
        pdf: ConvertedPDF,
        document: PDFDocument?,
        pdfView: PDFView?,
        currentPageIndex: Int
    ) -> String {
        var lines: [String] = []
        let divider = "────────────────────────────────────────"
        
        lines.append("🔍 [INKSYNC PRO PDF DIAGNOSTIC REPORT]")
        lines.append("⏱ Timestamp: \(Date().formatted(date: .numeric, time: .standard))")
        lines.append(divider)

        // 1. FILE & SANDBOX INTEGRITY
        lines.append("📁 [1. File & Sandbox Layer]")
        lines.append(" • Model Name: \(pdf.name)")
        lines.append(" • Model URL: \(pdf.url.absoluteString)")
        lines.append(" • File Extension: \(pdf.url.pathExtension)")
        let exists = FileManager.default.fileExists(atPath: pdf.url.path)
        lines.append(" • File Exists at Path: \(exists ? "✅ YES" : "❌ NO")")
        let isReadable = FileManager.default.isReadableFile(atPath: pdf.url.path)
        lines.append(" • File Is Readable: \(isReadable ? "✅ YES" : "❌ NO")")
        
        if let attr = try? FileManager.default.attributesOfItem(atPath: pdf.url.path) {
            let size = attr[.size] as? Int64 ?? 0
            lines.append(" • File Size on Disk: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) (\(size) bytes)")
            let modDate = attr[.modificationDate] as? Date
            lines.append(" • Modified Date: \(modDate?.formatted() ?? "Unknown")")
        } else {
            lines.append(" • File Attributes: ⚠️ Could not fetch attributes")
        }

        // 2. PDFDOCUMENT DECODE & PERMISSIONS
        lines.append(divider)
        lines.append("📄 [2. PDFDocument Health]")
        if let doc = document {
            lines.append(" • Document Loaded: ✅ YES")
            lines.append(" • Page Count: \(doc.pageCount)")
            lines.append(" • Is Locked (DRM/Password): \(doc.isLocked ? "🔒 LOCKED" : "🔓 UNLOCKED")")
            lines.append(" • Allows Printing: \(doc.allowsPrinting ? "✅ YES" : "❌ NO")")
            lines.append(" • Allows Copying: \(doc.allowsCopying ? "✅ YES" : "❌ NO")")
            lines.append(" • Document Attributes Count: \(doc.documentAttributes?.count ?? 0)")
            if let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
                lines.append("   - Title: \"\(title)\"")
            }
            if let author = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String {
                lines.append("   - Author: \"\(author)\"")
            }
            if let producer = doc.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String {
                lines.append("   - Producer: \"\(producer)\"")
            }
            if let creator = doc.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String {
                lines.append("   - Creator: \"\(creator)\"")
            }
            lines.append(" • Major Version: \(doc.majorVersion).\(doc.minorVersion)")
        } else {
            lines.append(" • Document Loaded: ❌ NIL (Document failed to initialize)")
        }

        // 3. CURRENT PAGE VECTOR & TEXT INSPECTION
        lines.append(divider)
        lines.append("🔍 [3. Current Page (Index: \(currentPageIndex))]")
        if let doc = document, let page = doc.page(at: currentPageIndex) {
            let mediaBox = page.bounds(for: .mediaBox)
            let cropBox = page.bounds(for: .cropBox)
            let artBox = page.bounds(for: .artBox)
            let bleedBox = page.bounds(for: .bleedBox)
            lines.append(" • MediaBox: \(formatRect(mediaBox))")
            lines.append(" • CropBox: \(formatRect(cropBox))")
            lines.append(" • ArtBox: \(formatRect(artBox))")
            lines.append(" • BleedBox: \(formatRect(bleedBox))")
            lines.append(" • Rotation: \(page.rotation)°")
            lines.append(" • Character Count: \(page.numberOfCharacters)")
            
            if let text = page.string, !text.isEmpty {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = trimmed.prefix(120).replacingOccurrences(of: "\n", with: " ")
                lines.append(" • Extracted Text: \"\(preview)...\" (Length: \(trimmed.count) chars)")
            } else {
                lines.append(" • Extracted Text: ⚠️ NONE (Pure image/vector or DRM text)")
            }
            
            // Check thumbnail generation
            let thumb = page.thumbnail(of: CGSize(width: 60, height: 80), for: .cropBox)
            lines.append(" • PDFKit Thumbnail Render: \(thumb.size.width > 0 ? "✅ Succeeded (\(Int(thumb.size.width))×\(Int(thumb.size.height)))" : "❌ Failed")")
        } else {
            lines.append(" • Current Page: ❌ NIL (Could not fetch page at index \(currentPageIndex))")
        }

        // 4. PDFVIEW HIERARCHY & SCALE METRICS
        lines.append(divider)
        lines.append("📐 [4. PDFView Layout & Scale Engine]")
        if let pv = pdfView {
            lines.append(" • View Bounds: \(Int(pv.bounds.width))×\(Int(pv.bounds.height)) pt")
            lines.append(" • Scale Factor: \(String(format: "%.4f", pv.scaleFactor))")
            lines.append(" • Fit-to-Width Scale (scaleFactorForSizeToFit): \(String(format: "%.4f", pv.scaleFactorForSizeToFit))")
            lines.append(" • Min / Max Scale Factor: \(String(format: "%.4f", pv.minScaleFactor)) / \(String(format: "%.4f", pv.maxScaleFactor))")
            lines.append(" • AutoScales Enabled: \(pv.autoScales ? "✅ YES" : "❌ NO")")
            lines.append(" • Display Mode: \(displayModeString(pv.displayMode))")
            lines.append(" • Displays As Book: \(pv.displaysAsBook ? "📖 YES" : "📄 NO")")
            lines.append(" • Display Direction: \(pv.displayDirection == .horizontal ? "Horizontal ↔" : "Vertical ↕")")
            lines.append(" • Is Opaque: \(pv.isOpaque ? "YES" : "NO")")
            lines.append(" • Background Color: \(String(describing: pv.backgroundColor))")
            lines.append(" • Page Break Margins: L:\(Int(pv.pageBreakMargins.left)) R:\(Int(pv.pageBreakMargins.right)) T:\(Int(pv.pageBreakMargins.top)) B:\(Int(pv.pageBreakMargins.bottom))")
            
            if let sv = pv.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                lines.append(" • Underlying UIScrollView:")
                lines.append("   - Content Size: \(Int(sv.contentSize.width))×\(Int(sv.contentSize.height))")
                lines.append("   - Zoom Scale: \(String(format: "%.4f", sv.zoomScale)) (Min: \(String(format: "%.4f", sv.minimumZoomScale)), Max: \(String(format: "%.4f", sv.maximumZoomScale)))")
                lines.append("   - Content Offset: (\(Int(sv.contentOffset.x)), \(Int(sv.contentOffset.y)))")
            }
        } else {
            lines.append(" • PDFView Reference: ⚠️ NIL (View not attached yet)")
        }

        // 5. SHADER & FILTER PIPELINE
        lines.append(divider)
        lines.append("🎨 [5. Color & Shader Pipeline]")
        let prefs = EBookPreferences.shared
        lines.append(" • Active Filter Preset: \(UserDefaults.standard.string(forKey: "activeFilterPreset") ?? "original")")
        lines.append(" • Reader Theme: \(prefs.themeRaw)")
        lines.append(" • Dual Page Pref: \(prefs.pdfDualPage ? "YES" : "NO") (Auto-landscape: \(prefs.autoLandscapeDualPage ? "YES" : "NO"))")

        lines.append(divider)
        let finalReport = lines.joined(separator: "\n")
        self.lastReport = finalReport
        self.lastLoggedTimestamp = Date()

        // Also broadcast to Logger
        Logger.shared.log("=== PDF DIAGNOSTIC REPORT ===\n\(finalReport)", category: "PDFDiagnostic", type: .info)

        return finalReport
    }

    /// Renders the page directly via low-level CoreGraphics CGContext to verify raw rendering capability.
    func performDirectCoreGraphicsRender(document: PDFDocument?, pageIndex: Int, targetSize: CGSize = CGSize(width: 400, height: 600)) -> UIImage? {
        guard let doc = document, let page = doc.page(at: pageIndex) else { return nil }
        let pageRect = page.bounds(for: .cropBox)
        guard pageRect.width > 0 && pageRect.height > 0 else { return nil }

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(origin: .zero, size: targetSize))

            cg.saveGState()
            cg.translateBy(x: 0, y: targetSize.height)
            cg.scaleBy(x: 1.0, y: -1.0)

            let scaleX = targetSize.width / pageRect.width
            let scaleY = targetSize.height / pageRect.height
            let fitScale = min(scaleX, scaleY)
            let drawWidth = pageRect.width * fitScale
            let drawHeight = pageRect.height * fitScale
            let offsetX = (targetSize.width - drawWidth) / 2.0
            let offsetY = (targetSize.height - drawHeight) / 2.0

            cg.translateBy(x: offsetX, y: offsetY)
            cg.scaleBy(x: fitScale, y: fitScale)
            page.draw(with: .cropBox, to: cg)
            cg.restoreGState()
        }
        self.directRenderImage = image
        return image
    }

    private func formatRect(_ r: CGRect) -> String {
        "(\(Int(r.origin.x)), \(Int(r.origin.y)), \(Int(r.size.width))×\(Int(r.size.height)))"
    }

    private func displayModeString(_ mode: PDFDisplayMode) -> String {
        switch mode {
        case .singlePage: return "Single Page (.singlePage)"
        case .singlePageContinuous: return "Single Page Continuous (.singlePageContinuous)"
        case .twoUp: return "Two-Up Facing (.twoUp)"
        case .twoUpContinuous: return "Two-Up Continuous (.twoUpContinuous)"
        @unknown default: return "Unknown (\(mode.rawValue))"
        }
    }
}

// MARK: - Floating Diagnostic HUD View
struct PDFDiagnosticHUDView: View {
    @ObservedObject var diagnosticEngine = PDFDiagnosticEngine.shared
    let pdf: ConvertedPDF
    let document: PDFDocument?
    let pdfView: PDFView?
    let currentPageIndex: Int
    var onDismiss: () -> Void

    @State private var copiedToClipboard: Bool = false
    @State private var showingDirectRenderPreview: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("PDF Reader Diagnostics", systemImage: "stethoscope")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                Button(action: {
                    UIPasteboard.general.string = diagnosticEngine.lastReport
                    withAnimation(.spring()) { copiedToClipboard = true }
                    HapticEngine.success()
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await MainActor.run { copiedToClipboard = false }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: copiedToClipboard ? "checkmark" : "doc.on.doc")
                        Text(copiedToClipboard ? "Copied!" : "Copy Log")
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(copiedToClipboard ? .green : .orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.12), in: Capsule())
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().background(Color.white.opacity(0.15))

            // Action Toolbar
            HStack(spacing: 12) {
                Button(action: {
                    _ = diagnosticEngine.inspect(
                        pdf: pdf,
                        document: document,
                        pdfView: pdfView,
                        currentPageIndex: currentPageIndex
                    )
                    HapticEngine.selection()
                }) {
                    Label("Re-Inspect Now", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                Button(action: {
                    showingDirectRenderPreview.toggle()
                    if showingDirectRenderPreview {
                        _ = diagnosticEngine.performDirectCoreGraphicsRender(
                            document: document,
                            pageIndex: currentPageIndex
                        )
                    }
                    HapticEngine.selection()
                }) {
                    Label(showingDirectRenderPreview ? "Hide CG Render" : "Test Raw CG Render", systemImage: "photo.badge.checkmark")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(showingDirectRenderPreview ? Color.orange.opacity(0.3) : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.2))

            // Direct Render Test Image Overlay
            if showingDirectRenderPreview, let img = diagnosticEngine.directRenderImage {
                VStack(spacing: 4) {
                    Text("Direct CoreGraphics Render (Bypassing PDFView):")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange, lineWidth: 1))
                }
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.3))
            }

            // Scrollable Diagnostic Log Text
            ScrollView(.vertical, showsIndicators: true) {
                Text(diagnosticEngine.lastReport)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(maxHeight: 340)
        }
        .frame(maxWidth: 540)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        .padding(16)
        .onAppear {
            _ = diagnosticEngine.inspect(
                pdf: pdf,
                document: document,
                pdfView: pdfView,
                currentPageIndex: currentPageIndex
            )
        }
    }
}

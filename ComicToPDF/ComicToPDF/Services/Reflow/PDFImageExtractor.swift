import Foundation
import PDFKit
import UIKit

public struct ExtractedPDFImage: Identifiable, Sendable {
    public let id: UUID
    public let pageIndex: Int
    public let imagePath: String
    public let rect: CGRect

    public init(id: UUID = UUID(), pageIndex: Int, imagePath: String, rect: CGRect) {
        self.id = id
        self.pageIndex = pageIndex
        self.imagePath = imagePath
        self.rect = rect
    }
}

public final class PDFImageExtractor: Sendable {
    public static let shared = PDFImageExtractor()
    private init() {}

    /// Extracts illustration graphics for pages that lack digital text blocks, writing them to a local cache folder as lightweight JPEGs.
    public func extractImages(
        from document: PDFDocument,
        pdfUUID: String,
        nonTextPages: Set<Int>
    ) async -> [ExtractedPDFImage] {
        guard !nonTextPages.isEmpty else { return [] }

        let fileManager = FileManager.default
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return [] }
        let targetDir = cacheDir.appendingPathComponent("ReflowPDF/\(pdfUUID)/images", isDirectory: true)

        do {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } catch {
            return []
        }

        var extracted: [ExtractedPDFImage] = []
        let sortedPages = nonTextPages.sorted()

        for (idx, pageIndex) in sortedPages.enumerated() {
            if Task.isCancelled { break }
            guard let page = document.page(at: pageIndex) else { continue }

            let pageImageResult: ExtractedPDFImage? = autoreleasepool {
                return renderPageIllustration(page, pageIndex: pageIndex, targetDir: targetDir)
            }

            if let img = pageImageResult {
                extracted.append(img)
            }

            if idx % 5 == 0 {
                await Task.yield()
            }
        }

        return extracted
    }

    private func renderPageIllustration(_ page: PDFPage, pageIndex: Int, targetDir: URL) -> ExtractedPDFImage? {
        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 0 && pageBounds.height > 0 else { return nil }

        // Downscale to max dimension 1024pt to preserve memory & prevent GPU texture crashes
        let maxDimension: CGFloat = 1024.0
        let aspect = pageBounds.width / pageBounds.height
        let targetSize: CGSize
        if pageBounds.width > pageBounds.height {
            let width = min(pageBounds.width, maxDimension)
            targetSize = CGSize(width: width, height: width / aspect)
        } else {
            let height = min(pageBounds.height, maxDimension)
            targetSize = CGSize(width: height * aspect, height: height)
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0 // 1x scale to prevent 3x retina memory bloat
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let pageImage = renderer.image { ctx in
            UIColor.white.set()
            ctx.fill(CGRect(origin: .zero, size: targetSize))

            let cgCtx = ctx.cgContext
            cgCtx.translateBy(x: 0, y: targetSize.height)
            cgCtx.scaleBy(x: targetSize.width / pageBounds.width, y: -targetSize.height / pageBounds.height)
            page.draw(with: .mediaBox, to: cgCtx)
        }

        let imageName = "fig_page_\(pageIndex + 1).jpg"
        let imageURL = targetDir.appendingPathComponent(imageName)

        guard let jpegData = pageImage.jpegData(compressionQuality: 0.75) else { return nil }

        do {
            try jpegData.write(to: imageURL, options: .atomic)
            return ExtractedPDFImage(pageIndex: pageIndex, imagePath: imageURL.path, rect: pageBounds)
        } catch {
            Logger.shared.log("PDFImageExtractor: Failed to write image for page \(pageIndex + 1): \(error.localizedDescription)", category: "Reflow", type: .warning)
            return nil
        }
    }
}

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

@MainActor
public final class PDFImageExtractor: Sendable {
    public static let shared = PDFImageExtractor()
    private init() {}

    /// Extracts embedded image graphics from PDF document pages and writes them to local cache folder.
    public func extractImages(from document: PDFDocument, pdfUUID: String) -> [ExtractedPDFImage] {
        let fileManager = FileManager.default
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return [] }
        let targetDir = cacheDir.appendingPathComponent("ReflowPDF/\(pdfUUID)/images", isDirectory: true)

        do {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } catch {
            return []
        }

        var extracted: [ExtractedPDFImage] = []
        let pageCount = document.pageCount

        for i in 0..<pageCount {
            guard let page = document.page(at: i) else { continue }
            let pageImages = extractImagesFromPage(page, pageIndex: i, targetDir: targetDir)
            extracted.append(contentsOf: pageImages)
        }

        return extracted
    }

    private func extractImagesFromPage(_ page: PDFPage, pageIndex: Int, targetDir: URL) -> [ExtractedPDFImage] {
        var result: [ExtractedPDFImage] = []

        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 0 && pageBounds.height > 0 else { return [] }

        let renderer = UIGraphicsImageRenderer(size: pageBounds.size)
        let pageImage = renderer.image { ctx in
            UIColor.white.set()
            ctx.fill(pageBounds)
            ctx.cgContext.translateBy(x: 0, y: pageBounds.height)
            ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }

        let imageName = "fig_page_\(pageIndex + 1).png"
        let imageURL = targetDir.appendingPathComponent(imageName)

        if let pngData = pageImage.pngData() {
            do {
                try pngData.write(to: imageURL)
                result.append(ExtractedPDFImage(pageIndex: pageIndex, imagePath: imageURL.path, rect: pageBounds))
            } catch {}
        }

        return result
    }
}

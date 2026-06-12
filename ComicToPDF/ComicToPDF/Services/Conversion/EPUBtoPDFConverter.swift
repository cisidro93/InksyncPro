import UIKit
import ZIPFoundation
import PDFKit

final class EPUBtoPDFConverter: Sendable {

    func convertEPUBtoPDF(_ epubURL: URL, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        // Phase 1 — file I/O on a background queue (safe for UIImage(contentsOfFile:))
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                Logger.shared.log("Converting EPUB to PDF...", category: "EPUB2PDF")

                // 1. Extract EPUB into a temp directory
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                Logger.shared.log("Extracting EPUB...", category: "EPUB2PDF")
                try FileManager.default.unzipItem(at: epubURL, to: tempDir)

                // 2. Load raw images from the extracted EPUB (file I/O only — no UIGraphics here)
                let images = try self.extractImagesFromEPUB(at: tempDir)
                Logger.shared.log("Found \(images.count) images in EPUB", category: "EPUB2PDF")

                guard !images.isEmpty else {
                    throw EPUBConversionError.noPages
                }

                // Phase 2 — UIGraphics work MUST run on the main thread.
                // Hop to main for strip reconstruction (UIGraphicsBeginImageContextWithOptions)
                // and PDF creation (UIGraphicsBeginPDFContextToFile).
                DispatchQueue.main.async {
                    do {
                        let finalPages = self.reconstructPagesIfNeeded(images)
                        Logger.shared.log("Final page count: \(finalPages.count)", category: "EPUB2PDF")

                        guard !finalPages.isEmpty else {
                            completion(.failure(EPUBConversionError.noPages))
                            return
                        }

                        let pdfURL = try self.createPDF(from: finalPages, basedOn: epubURL, in: tempDir)
                        Logger.shared.log("PDF created: \(pdfURL.lastPathComponent)", category: "EPUB2PDF", type: .success)
                        completion(.success(pdfURL))
                    } catch {
                        Logger.shared.log("EPUB rendering failed: \(error)", category: "EPUB2PDF", type: .error)
                        completion(.failure(error))
                    }
                }

            } catch {
                Logger.shared.log("EPUB to PDF conversion failed: \(error)", category: "EPUB2PDF", type: .error)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Extract Images from EPUB
    // Safe to call from a background thread — only performs file I/O via UIImage(contentsOfFile:),
    // which is documented as thread-safe for reading existing files.
    private func extractImagesFromEPUB(at directory: URL) throws -> [UIImage] {
        var images: [(url: URL, image: UIImage)] = []

        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "gif", "webp"].contains(ext) {
                    if let image = UIImage(contentsOfFile: fileURL.path) {
                        images.append((url: fileURL, image: image))
                    }
                }
            }
        }

        images.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }
        return images.map { $0.image }
    }

    // MARK: - Strip Reconstruction
    // ⚠️ Must be called on the main thread — uses UIGraphicsBeginImageContextWithOptions.
    private func reconstructPagesIfNeeded(_ images: [UIImage]) -> [UIImage] {
        guard !images.isEmpty, let first = images.first else { return images }

        let aspectRatio = first.size.width / first.size.height
        if aspectRatio > 2.0 {
            Logger.shared.log(
                "Detected horizontal strips (aspect ratio \(String(format: "%.2f", aspectRatio))) — reconstructing pages.",
                category: "EPUB2PDF"
            )
            let stripsPerPage = detectStripsPerPage(images)
            return reconstructPages(from: images, stripsPerPage: stripsPerPage)
        } else {
            return images
        }
    }

    private func detectStripsPerPage(_ images: [UIImage]) -> Int {
        let totalCount = images.count
        for strips in [10, 8, 7, 6, 5, 4] {
            if totalCount % strips == 0 { return strips }
        }
        if totalCount == 32 { return 8 }
        return 6
    }

    // ⚠️ Must be called on the main thread — uses UIGraphicsBeginImageContextWithOptions.
    private func reconstructPages(from strips: [UIImage], stripsPerPage: Int) -> [UIImage] {
        var pages: [UIImage] = []
        let pageCount = strips.count / stripsPerPage
        for pageNum in 0..<pageCount {
            let startIdx = pageNum * stripsPerPage
            let endIdx   = min(startIdx + stripsPerPage, strips.count)
            let pageStrips = Array(strips[startIdx..<endIdx])
            if let fullPage = stitchStripsVertically(pageStrips) {
                pages.append(fullPage)
            }
        }
        return pages
    }

    // ⚠️ Must be called on the main thread — uses UIGraphicsBeginImageContextWithOptions.
    private func stitchStripsVertically(_ strips: [UIImage]) -> UIImage? {
        guard !strips.isEmpty else { return nil }
        let width       = strips[0].size.width
        let totalHeight = strips.reduce(0) { $0 + $1.size.height }
        let scale       = strips[0].scale

        UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: totalHeight), false, scale)
        defer { UIGraphicsEndImageContext() }

        var yOffset: CGFloat = 0
        for strip in strips {
            strip.draw(at: CGPoint(x: 0, y: yOffset))
            yOffset += strip.size.height
        }
        return UIGraphicsGetImageFromCurrentImageContext()
    }

    // MARK: - Create PDF
    // ⚠️ Must be called on the main thread — uses UIGraphicsBeginPDFContextToFile.
    private func createPDF(from images: [UIImage], basedOn originalURL: URL, in directory: URL) throws -> URL {
        let pdfName = originalURL.deletingPathExtension().lastPathComponent + "_converted.pdf"
        let pdfURL  = directory.appendingPathComponent(pdfName)

        UIGraphicsBeginPDFContextToFile(pdfURL.path, .zero, nil)
        for image in images {
            let pageRect = CGRect(origin: .zero, size: image.size)
            UIGraphicsBeginPDFPageWithInfo(pageRect, nil)
            image.draw(in: pageRect)
        }
        UIGraphicsEndPDFContext()

        return pdfURL
    }
}


enum EPUBConversionError: LocalizedError {
    case noPages
    case extractionFailed
    
    var errorDescription: String? {
        switch self {
        case .noPages:
            return "No pages found in EPUB"
        case .extractionFailed:
            return "Failed to extract EPUB contents"
        }
    }
}

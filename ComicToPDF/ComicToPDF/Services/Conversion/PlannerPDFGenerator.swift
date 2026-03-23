import Foundation
import UIKit
import PencilKit
import PDFKit

/// The Engine responsible for flattening an editable .inksycPlanner into a rigid, native, hyperlinked PDF
class PlannerPDFGenerator {
    
    /// Generates a PDF File from a given PlannerProject and writes it to disk.
    /// - Parameters:
    ///   - project: The active PlannerProject being exported.
    ///   - outputURL: Destination URL for the `.pdf` file.
    ///   - progress: Optional callback for UI progress tracking.
    static func generate(from project: PlannerProject, to outputURL: URL, progress: ((Double) -> Void)? = nil) throws {
        let totalPages = Double(project.pages.count)
        var current = 0.0
        
        let targetSize = project.targetDeviceProfile.resolution ?? CGSize(width: 1200, height: 1800)
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: targetSize), format: format)
        
        // Accumulate link zones to inject later as PDFAnnotations. Link rects must map to a specific UUID.
        var pendingLinks: [(pageIndex: Int, linkRect: CGRect, targetUUID: UUID)] = []
        
        // Map page UUIDs to physical PDF indexes for dynamic link resolution
        var pageUUIDToIndexMap: [UUID: Int] = [:]
        for (index, page) in project.pages.enumerated() {
            pageUUIDToIndexMap[page.id] = index
        }
        
        try renderer.writePDF(to: outputURL) { context in
            for (index, page) in project.pages.enumerated() {
                autoreleasepool {
                    let pageRect = CGRect(origin: .zero, size: targetSize)
                    context.beginPage(withBounds: pageRect, pageInfo: [:])
                    
                    // 1. Draw Background (White or Imported PDF raster)
                    if let bgData = page.backgroundImageData, let bgImage = UIImage(data: bgData) {
                        bgImage.draw(in: pageRect)
                    } else {
                        UIColor.white.setFill()
                        context.fill(pageRect)
                    }
                    
                    // 2. Draw Vector Elements
                    for element in page.elements {
                        let absoluteRect = CoordinateConverter.denormalize(rect: element.rect, in: targetSize)
                        
                        switch element.type {
                        case .rectangle:
                            let path = UIBezierPath(rect: absoluteRect)
                            path.lineWidth = element.strokeWidth ?? 2.0
                            UIColor.black.setStroke()
                            path.stroke()
                        case .circle:
                            let path = UIBezierPath(ovalIn: absoluteRect)
                            path.lineWidth = element.strokeWidth ?? 2.0
                            UIColor.black.setStroke()
                            path.stroke()
                        case .line:
                            let path = UIBezierPath()
                            path.move(to: CGPoint(x: absoluteRect.minX, y: absoluteRect.minY))
                            path.addLine(to: CGPoint(x: absoluteRect.maxX, y: absoluteRect.maxY))
                            path.lineWidth = element.strokeWidth ?? 2.0
                            UIColor.black.setStroke()
                            path.stroke()
                        case .image:
                            // Draw the embedded sticker/photo
                            if let imgData = element.imageData, let image = UIImage(data: imgData) {
                                image.draw(in: absoluteRect)
                            }
                        case .text:
                            if let textStr = element.text {
                                let font = UIFont.systemFont(ofSize: element.strokeWidth ?? 24)
                                let attrs: [NSAttributedString.Key: Any] = [.font: font]
                                let attrStr = NSAttributedString(string: textStr, attributes: attrs)
                                attrStr.draw(in: absoluteRect)
                            }
                        case .linkZone:
                            // Link Zones are invisible but we must track them for the Annotation pass
                            if let targetUUID = element.targetPageID {
                                pendingLinks.append((pageIndex: index, linkRect: absoluteRect, targetUUID: targetUUID))
                            }
                        }
                    }
                    
                    // 3. Draw PencilKit Strokes over everything
                    do {
                        let drawing = try PKDrawing(data: page.drawingData)
                        // Verify the drawing actually has strokes and non-zero bounds to prevent UIKit crashes
                        if !drawing.bounds.isEmpty && !drawing.bounds.isNull && drawing.bounds.width > 1 {
                            let drawingImage = drawing.image(from: drawing.bounds, scale: 1.0)
                            drawingImage.draw(in: drawing.bounds)
                        }
                    } catch {
                        Logger.shared.log("Failed to decode PKDrawing on page \(index)", category: "PlannerPDF", type: .warning)
                    }
                    
                    current += 1
                    progress?(current / totalPages)
                }
            }
        }
        
        // 4. Inject Hyperlink Annotations dynamically based on UUIDs
        if !pendingLinks.isEmpty, let pdfDocument = PDFDocument(url: outputURL) {
            for link in pendingLinks {
                guard let physicalTargetIndex = pageUUIDToIndexMap[link.targetUUID],
                      let sourcePage = pdfDocument.page(at: link.pageIndex),
                      let destPage = pdfDocument.page(at: physicalTargetIndex) else {
                    continue
                }
                
                // Flip Y coordinate for PDFKit standard bounds
                let pdfBounds = sourcePage.bounds(for: .mediaBox)
                let pdfY = pdfBounds.height - link.linkRect.maxY
                let annotationRect = CGRect(x: link.linkRect.minX, y: pdfY, width: link.linkRect.width, height: link.linkRect.height)
                
                let linkAnnotation = PDFAnnotation(bounds: annotationRect, forType: .link, withProperties: nil)
                let destination = PDFDestination(page: destPage, at: CGPoint(x: 0, y: destPage.bounds(for: .mediaBox).height))
                linkAnnotation.action = PDFActionGoTo(destination: destination)
                
                sourcePage.addAnnotation(linkAnnotation)
            }
            pdfDocument.write(to: outputURL)
        }
        
        Logger.shared.log("Generated AI Planner PDF at \(outputURL.path)", category: "PlannerPDF", type: .success)
    }
}

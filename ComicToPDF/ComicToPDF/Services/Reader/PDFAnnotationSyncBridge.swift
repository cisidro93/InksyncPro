import Foundation
import PDFKit
import PencilKit
import SwiftUI
import UIKit

// MARK: - Native PDF Annotation Interoperability Bridge

/// Bi-directional synchronization service bridging InkSync Pro's `AnnotationStore`
/// with native standard Adobe/ISO 32000 PDF annotations (`/Ink`, `/Highlight`, `/Text`).
@MainActor
final class PDFAnnotationSyncBridge {
    
    static let shared = PDFAnnotationSyncBridge()
    private var pendingDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private var dirtyPDFs: Set<UUID> = []
    
    init() {}
    
    /// Marks a document dirty so its annotations will be serialized to disk on save.
    func markDirty(_ pdfID: UUID) {
        dirtyPDFs.insert(pdfID)
    }

    /// Checks if a document has unsaved annotation mutations.
    func isDirty(_ pdfID: UUID) -> Bool {
        return dirtyPDFs.contains(pdfID)
    }
    
    // MARK: - Apply Inksync Annotations to Live PDFDocument
    
    /// Injects all InkSync Pro highlights, sticky notes, and vector drawings from `AnnotationStore`
    /// directly onto the live `PDFDocument` pages for active reading.
    @MainActor
    func applyStoreAnnotations(for pdfID: UUID, to document: PDFDocument) {
        let storeAnnotations = AnnotationStore.shared.annotations(for: pdfID)
        guard !storeAnnotations.isEmpty else { return }
        
        for annotation in storeAnnotations {
            guard annotation.pageIndex >= 0 && annotation.pageIndex < document.pageCount,
                  let page = document.page(at: annotation.pageIndex) else { continue }
            
            let pageBounds = page.bounds(for: .cropBox)
            
            switch annotation.kind {
            case .highlight, .underline, .strikeOut:
                let nativeType: PDFAnnotationSubtype
                let nativeTypeName: String
                switch annotation.kind {
                case .underline:
                    nativeType = .underline
                    nativeTypeName = "Underline"
                case .strikeOut:
                    nativeType = .strikeOut
                    nativeTypeName = "StrikeOut"
                default:
                    nativeType = .highlight
                    nativeTypeName = "Highlight"
                }

                // Check if this annotation is already attached to the page (prevent duplicates)
                let alreadyPresent = page.annotations.contains { native in
                    if native.userName == annotation.id.uuidString { return true }
                    guard native.type == nativeTypeName || native.type == "/\(nativeTypeName)" || native.type == nativeType.rawValue else { return false }
                    if let b = annotation.bounds {
                        let expected = CGRect(
                            x: pageBounds.minX + (b.x * pageBounds.width),
                            y: pageBounds.minY + (b.y * pageBounds.height),
                            width: b.width * pageBounds.width,
                            height: b.height * pageBounds.height
                        )
                        let spatialMatch = native.bounds.insetBy(dx: -4, dy: -4).intersects(expected)
                        if let text = annotation.selectedText, let c = native.contents, !text.isEmpty && c == text {
                            return spatialMatch
                        }
                        return spatialMatch
                    } else if let text = annotation.selectedText, let c = native.contents, !text.isEmpty && c == text {
                        return true
                    }
                    return false
                }
                page.displaysAnnotations = true
                guard !alreadyPresent else { continue }
                
                let highlightColor: UIColor
                if let hex = annotation.colorHex, let c = UIColor(hexString: hex) {
                    highlightColor = c.withAlphaComponent(annotation.kind == .highlight ? 0.60 : 0.85)
                } else {
                    highlightColor = UIColor.systemYellow.withAlphaComponent(0.55)
                }
                
                var didAttach = false

                // Primary: reconstruct tight line-by-line quads from recorded text scoped strictly to this single page
                if let text = annotation.selectedText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let pageText = page.string ?? ""
                    if let range = pageText.range(of: text, options: .caseInsensitive) {
                        let nsRange = NSRange(range, in: pageText)
                        if let pageSel = page.selection(for: nsRange) {
                            let lines = pageSel.selectionsByLine()
                            let targetLines = lines.isEmpty ? [pageSel] : lines
                            let validRects = targetLines.compactMap { $0.bounds(for: page) }.filter { $0 != .zero && $0.width > 2 && $0.height > 2 }
                            if !validRects.isEmpty {
                                let unionBox = PDFHighlightGeometryHelper.unionBounds(for: validRects)
                                let nativeHighlight = PDFAnnotation(bounds: unionBox, forType: nativeType, withProperties: nil)
                                nativeHighlight.userName = annotation.id.uuidString
                                nativeHighlight.color = highlightColor
                                nativeHighlight.contents = text
                                nativeHighlight.shouldDisplay = true
                                nativeHighlight.shouldPrint = true
                                nativeHighlight.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: validRects, relativeTo: unionBox)
                                page.addAnnotation(nativeHighlight)
                                didAttach = true
                            }
                        }
                    }
                }

                // Fallback: reconstruct from recorded normalized bounds
                if !didAttach, let b = annotation.bounds {
                    let bounds = CGRect(
                        x: pageBounds.minX + (b.x * pageBounds.width),
                        y: pageBounds.minY + (b.y * pageBounds.height),
                        width: b.width * pageBounds.width,
                        height: b.height * pageBounds.height
                    )
                    if bounds.width > 2 && bounds.height > 2 {
                        let nativeHighlight = PDFAnnotation(bounds: bounds, forType: nativeType, withProperties: nil)
                        nativeHighlight.userName = annotation.id.uuidString
                        nativeHighlight.color = highlightColor
                        nativeHighlight.contents = annotation.selectedText ?? annotation.noteText
                        nativeHighlight.shouldDisplay = true
                        nativeHighlight.shouldPrint = true
                        nativeHighlight.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: bounds)
                        page.addAnnotation(nativeHighlight)
                    }
                }
                
            case .note:
                let noteOrigin = CGPoint(x: pageBounds.minX + 30, y: pageBounds.maxY - 80)
                let noteRect = CGRect(origin: noteOrigin, size: CGSize(width: 24, height: 24))
                let nativeText = PDFAnnotation(bounds: noteRect, forType: .text, withProperties: nil)
                nativeText.color = UIColor.systemPurple
                nativeText.contents = annotation.noteText ?? annotation.selectedText ?? ""
                nativeText.iconType = .note
                page.addAnnotation(nativeText)
                
            case .ink:
                if let drawingData = annotation.drawingData,
                   let drawing = try? PKDrawing(data: drawingData) {
                    let nativeInk = PDFAnnotation(bounds: pageBounds, forType: .ink, withProperties: nil)
                    nativeInk.userName = annotation.id.uuidString
                    nativeInk.contents = annotation.drawingOCRText ?? "Handwritten Note"
                    if let hex = annotation.colorHex, let c = UIColor(hexString: hex) {
                        nativeInk.color = c
                    } else if let firstStroke = drawing.strokes.first {
                        nativeInk.color = firstStroke.ink.color
                    } else {
                        nativeInk.color = UIColor.systemBlue
                    }
                    for stroke in drawing.strokes {
                        let bezier = UIBezierPath()
                        var first = true
                        for point in stroke.path {
                            let pt = point.location
                            let pdfPt = CGPoint(x: pt.x, y: pageBounds.height - pt.y)
                            if first {
                                bezier.move(to: pdfPt)
                                first = false
                            } else {
                                bezier.addLine(to: pdfPt)
                            }
                        }
                        nativeInk.add(bezier)
                    }
                    page.addAnnotation(nativeInk)
                }
                
            case .bookmark:
                break
            }
        }
        
        Logger.shared.log("PDFAnnotationSync: Applied \(storeAnnotations.count) annotations onto active PDF document", category: "PDF")
    }

    // MARK: - Remove Annotation from Live PDFDocument
    
    /// Removes a specific annotation from the live `PDFDocument` (matching by exact reference, userName UUID, bounds, or matching contents),
    /// schedules debounced disk persistence, and returns true if an annotation was found and removed.
    @discardableResult
    @MainActor
    func removeAnnotation(
        id: UUID,
        from document: PDFDocument,
        on pageIndex: Int? = nil,
        text: String? = nil,
        destinationURL: URL? = nil,
        pdfID: UUID? = nil,
        targetAnnotation: PDFAnnotation? = nil,
        bounds: CGRect? = nil
    ) -> Bool {
        var didRemove = false
        let idString = id.uuidString
        
        let targetPages: [PDFPage]
        if let idx = pageIndex, idx >= 0 && idx < document.pageCount, let page = document.page(at: idx) {
            targetPages = [page]
        } else {
            targetPages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        }
        
        for page in targetPages {
            let matching = page.annotations.filter { ann in
                if let target = targetAnnotation, ann === target { return true }
                if ann.userName == idString { return true }
                if let b = bounds, ann.bounds.intersects(b.insetBy(dx: -4, dy: -4)) {
                    let typeName = ann.type ?? ""
                    if typeName.contains("Highlight") || typeName.contains("Underline") || typeName.contains("StrikeOut") || typeName.contains("Text") {
                        return true
                    }
                }
                if let t = text, !t.isEmpty, let c = ann.contents, (c == t || c.contains(t) || t.contains(c)) {
                    let typeName = ann.type ?? ""
                    if typeName.contains("Highlight") || typeName.contains("Underline") || typeName.contains("StrikeOut") || typeName.contains("Text") {
                        if let b = bounds {
                            return ann.bounds.intersects(b.insetBy(dx: -4, dy: -4))
                        }
                        return true
                    }
                }
                return false
            }
            for ann in matching {
                page.removeAnnotation(ann)
                didRemove = true
            }
            if didRemove {
                page.displaysAnnotations = false
                page.displaysAnnotations = true
            }
        }
        
        if didRemove {
            Logger.shared.log("PDFAnnotationSync: Removed annotation \(idString) from document", category: "PDF", type: .info)
            scheduleDebouncedDiskSync(for: pdfID ?? id, in: document, at: destinationURL)
        }
        return didRemove
    }

    // MARK: - Sync & Persist to Document Disk Storage
    
    /// Non-blocking, debounced disk persistence for interactive highlighting.
    /// Defers PDF binary serialization to a trailing background task after user interactions cease.
    func scheduleDebouncedDiskSync(for pdfID: UUID, in document: PDFDocument, at destinationURL: URL? = nil) {
        guard let targetURL = destinationURL ?? document.documentURL else { return }
        markDirty(pdfID)
        
        pendingDebounceTasks[pdfID]?.cancel()
        pendingDebounceTasks[pdfID] = Task { @MainActor [weak self, weak document] in
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self = self, let doc = document else { return }
                self.pendingDebounceTasks.removeValue(forKey: pdfID)
                self.syncStoreToDocument(for: pdfID, in: doc, at: targetURL)
            } catch {
                // Task cancelled
            }
        }
    }
    
    /// Synchronizes all in-memory and SwiftData annotations from `AnnotationStore` directly into the live `PDFDocument`
    /// and offloads writing the updated document back to disk to a background utility queue without freezing the MainActor.
    func syncStoreToDocument(for pdfID: UUID, in document: PDFDocument, at destinationURL: URL? = nil, force: Bool = false) {
        pendingDebounceTasks[pdfID]?.cancel()
        pendingDebounceTasks.removeValue(forKey: pdfID)
        
        guard force || dirtyPDFs.contains(pdfID) else {
            Logger.shared.log("PDFAnnotationSync: Document \(pdfID) has no unsaved changes. Skipping redundant disk write.", category: "PDF")
            return
        }
        dirtyPDFs.remove(pdfID)
        
        applyStoreAnnotations(for: pdfID, to: document)
        guard let targetURL = destinationURL ?? document.documentURL else { return }
        Self.serializeAndWriteAsync(document: document, targetURL: targetURL, pdfID: pdfID)
    }

    @MainActor
    private static func serializeAndWriteAsync(document: PDFDocument, targetURL: URL, pdfID: UUID) {
        let didAccess = targetURL.startAccessingSecurityScopedResource()
        let op = BackgroundWriteOperation(
            document: document,
            targetURL: targetURL,
            pdfID: pdfID,
            didAccessSecurityScope: didAccess
        )
        op.start()
    }

    // MARK: - Export Inksync Annotations to Native PDFDocument
    
    /// Writes all InkSync Pro highlights, Pencil drawings, and Adler notes into the `PDFDocument` as native ISO annotations.
    @MainActor
    func exportAnnotations(for pdfID: UUID, to document: PDFDocument) {
        let storeAnnotations = AnnotationStore.shared.annotations(for: pdfID)
        
        for annotation in storeAnnotations {
            guard annotation.pageIndex >= 0 && annotation.pageIndex < document.pageCount,
                  let page = document.page(at: annotation.pageIndex) else { continue }
            
            let pageBounds = page.bounds(for: .cropBox)
            
            switch annotation.kind {
            case .highlight, .underline, .strikeOut:
                let nativeType: PDFAnnotationSubtype
                switch annotation.kind {
                case .underline: nativeType = .underline
                case .strikeOut: nativeType = .strikeOut
                default: nativeType = .highlight
                }
                
                // Create native annotation
                let bounds: CGRect
                if let b = annotation.bounds {
                    bounds = CGRect(
                        x: pageBounds.minX + (b.x * pageBounds.width),
                        y: pageBounds.minY + (b.y * pageBounds.height),
                        width: b.width * pageBounds.width,
                        height: b.height * pageBounds.height
                    )
                } else {
                    bounds = CGRect(x: pageBounds.minX + 20, y: pageBounds.maxY - 100, width: pageBounds.width - 40, height: 24)
                }
                guard bounds.width > 2, bounds.height > 2 else { continue }
                
                let nativeHighlight = PDFAnnotation(bounds: bounds, forType: nativeType, withProperties: nil)
                if let hex = annotation.colorHex, let c = UIColor(hexString: hex) {
                    nativeHighlight.color = c.withAlphaComponent(annotation.kind == .highlight ? 0.60 : 0.85)
                } else {
                    nativeHighlight.color = UIColor.systemYellow.withAlphaComponent(0.55)
                }
                nativeHighlight.contents = annotation.selectedText ?? annotation.noteText
                nativeHighlight.shouldDisplay = true
                nativeHighlight.shouldPrint = true
                nativeHighlight.quadrilateralPoints = PDFHighlightGeometryHelper.createQuadPoints(for: bounds)
                page.addAnnotation(nativeHighlight)
                
            case .note:
                // Create native /Text sticky note popup annotation
                let noteOrigin = CGPoint(x: pageBounds.minX + 30, y: pageBounds.maxY - 80)
                let noteRect = CGRect(origin: noteOrigin, size: CGSize(width: 24, height: 24))
                let nativeText = PDFAnnotation(bounds: noteRect, forType: .text, withProperties: nil)
                nativeText.color = UIColor.systemPurple
                nativeText.contents = annotation.noteText ?? annotation.selectedText ?? ""
                nativeText.iconType = .note
                page.addAnnotation(nativeText)
                
            case .ink:
                // Convert PencilKit drawing data to native vector /Ink paths preserving stroke color and metadata
                if let drawingData = annotation.drawingData,
                   let drawing = try? PKDrawing(data: drawingData) {
                    let nativeInk = PDFAnnotation(bounds: pageBounds, forType: .ink, withProperties: nil)
                    nativeInk.userName = annotation.id.uuidString
                    nativeInk.contents = annotation.drawingOCRText ?? "Handwritten Note"
                    if let hex = annotation.colorHex, let c = UIColor(hexString: hex) {
                        nativeInk.color = c
                    } else if let firstStroke = drawing.strokes.first {
                        nativeInk.color = firstStroke.ink.color
                    } else {
                        nativeInk.color = UIColor.systemBlue
                    }
                    
                    for stroke in drawing.strokes {
                        let bezier = UIBezierPath()
                        var first = true
                        for point in stroke.path {
                            let pt = point.location
                            let pdfPt = CGPoint(x: pt.x, y: pageBounds.height - pt.y)
                            if first {
                                bezier.move(to: pdfPt)
                                first = false
                            } else {
                                bezier.addLine(to: pdfPt)
                            }
                        }
                        nativeInk.add(bezier)
                    }
                    page.addAnnotation(nativeInk)

                    // Lossless dual-layer metadata embedding in document attributes
                    if var attrs = document.documentAttributes {
                        attrs["Inksync_Drawing_P\(annotation.pageIndex)"] = drawingData.base64EncodedString()
                        document.documentAttributes = attrs
                    }
                }
                
            case .bookmark:
                // Bookmarks are handled via document outline/navigation, skip page annotation
                break
            }
        }
        
        Logger.shared.log("PDFAnnotationSync: Exported \(storeAnnotations.count) annotations into native PDF document", category: "PDF")
    }

    // MARK: - Coordinate Helpers (intentionally removed quadrilateralPoints — PDFKit derives them from bounds)
    
    // MARK: - Import Native PDF Annotations into InkSync Pro
    
    /// Scans a `PDFDocument` for third-party native annotations (Acrobat, Preview, Edge)
    /// and imports them into InkSync Pro's `AnnotationStore`.
    @MainActor
    func importNativeAnnotations(from document: PDFDocument, for pdfID: UUID, preferredPageIndex: Int? = nil) async -> [Annotation] {
        var imported: [Annotation] = []
        let existingAnnotations = AnnotationStore.shared.annotations(for: pdfID)
        let existingIDs = Set(existingAnnotations.map { $0.id })
        
        // Build set of existing signatures (pageIndex_kindRaw_text) to prevent duplicate imports
        var existingSignatures = Set(existingAnnotations.compactMap { ann -> String? in
            let textKey = (ann.selectedText ?? ann.noteText ?? "\(ann.drawingData?.count ?? 0)")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !textKey.isEmpty else { return nil }
            return "\(ann.pageIndex)_\(ann.kind.rawValue)_\(textKey)"
        })
        
        // Track pages that already have ink annotations so we don't import duplicate ink
        let existingInkPages = Set(existingAnnotations.filter { $0.kind == .ink }.map { $0.pageIndex })

        let totalPages = document.pageCount
        guard totalPages > 0 else { return [] }
        
        // Prioritize active page and immediate neighbors first so reader opens in <50ms
        var pagesToProcess: [Int] = []
        if let preferred = preferredPageIndex, preferred >= 0, preferred < totalPages {
            pagesToProcess.append(preferred)
            if preferred > 0 { pagesToProcess.append(preferred - 1) }
            if preferred + 1 < totalPages { pagesToProcess.append(preferred + 1) }
        }
        let remaining = (0..<totalPages).filter { !pagesToProcess.contains($0) }
        pagesToProcess.append(contentsOf: remaining)
        
        for (step, pageIndex) in pagesToProcess.enumerated() {
            if step > 0 && step % 15 == 0 {
                await Task.yield()
            }
            guard let page = document.page(at: pageIndex) else { continue }
            guard !page.annotations.isEmpty else { continue }
            let pageBounds = page.bounds(for: .cropBox)
            
            for nativeAnn in page.annotations {
                guard let type = nativeAnn.type else { continue }
                
                // Map native annotation types (handling both standard and slash-prefixed strings)
                var kind: Annotation.AnnotationKind? = nil
                switch type {
                case "Highlight", "/Highlight":
                    kind = .highlight
                case "Underline", "/Underline":
                    kind = .underline
                case "StrikeOut", "/StrikeOut":
                    kind = .strikeOut
                case "Text", "/Text", "FreeText", "/FreeText":
                    kind = .note
                case "Ink", "/Ink":
                    kind = .ink
                default:
                    break
                }
                
                guard let mappedKind = kind else { continue }
                
                // If this annotation was created by InkSync Pro, nativeAnn.userName holds its UUID
                if let userName = nativeAnn.userName, let existingUUID = UUID(uuidString: userName) {
                    if existingIDs.contains(existingUUID) {
                        continue
                    }
                }
                
                let contentText = nativeAnn.contents ?? ""
                let textKey = contentText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                
                // Check signature deduplication
                if mappedKind != .ink && !textKey.isEmpty {
                    let sig = "\(pageIndex)_\(mappedKind.rawValue)_\(textKey)"
                    if existingSignatures.contains(sig) {
                        continue
                    }
                    existingSignatures.insert(sig)
                } else if mappedKind == .ink {
                    if existingInkPages.contains(pageIndex) {
                        continue
                    }
                }
                
                let boundsNorm = CodableCGRect(
                    x: Double((nativeAnn.bounds.minX - pageBounds.minX) / max(1, pageBounds.width)),
                    y: Double((nativeAnn.bounds.minY - pageBounds.minY) / max(1, pageBounds.height)),
                    width: Double(nativeAnn.bounds.width / max(1, pageBounds.width)),
                    height: Double(nativeAnn.bounds.height / max(1, pageBounds.height))
                )
                
                let colorHex = nativeAnn.color.toHexString()
                let targetID: UUID
                if let userName = nativeAnn.userName, let parsedUUID = UUID(uuidString: userName) {
                    targetID = parsedUUID
                } else {
                    targetID = UUID()
                }
                
                var newAnnotation = Annotation(
                    id: targetID,
                    pdfID: pdfID,
                    pageIndex: pageIndex,
                    chapterTitle: "Page \(pageIndex + 1)",
                    kind: mappedKind,
                    createdAt: nativeAnn.modificationDate ?? Date(),
                    modifiedAt: Date(),
                    colorHex: colorHex,
                    selectedText: (mappedKind == .highlight || mappedKind == .underline || mappedKind == .strikeOut) ? (contentText.isEmpty ? nil : contentText) : nil,
                    noteText: mappedKind == .note ? (contentText.isEmpty ? nil : contentText) : nil,
                    bounds: boundsNorm
                )
                
                if mappedKind == .ink {
                    if let rawBase64 = document.documentAttributes?["Inksync_Drawing_P\(pageIndex)"] as? String,
                       let data = Data(base64Encoded: rawBase64) {
                        newAnnotation.drawingData = data
                    }
                }
                
                imported.append(newAnnotation)
            }
        }
        
        if !imported.isEmpty {
            AnnotationStore.shared.addBatch(imported)
            Logger.shared.log("PDFAnnotationSync: Batch-imported \(imported.count) third-party annotations from PDF", category: "PDF")
        }
        return imported
    }
    
    // MARK: - Standalone Annotated PDF File Generation
    
    /// Generates a standalone annotated PDF file and writes it to the destination URL.
    @MainActor
    func generateAnnotatedPDF(
        from document: PDFDocument,
        for pdfID: UUID,
        saveTo destinationURL: URL
    ) throws -> URL {
        // Create an in-memory duplicate of the document to avoid mutating the active reader
        guard let data = document.dataRepresentation(),
              let exportedDoc = PDFDocument(data: data) else {
            throw PDFSyncError.documentSerializationFailed
        }
        
        self.exportAnnotations(for: pdfID, to: exportedDoc)
        
        guard exportedDoc.write(to: destinationURL) else {
            throw PDFSyncError.fileWriteFailed
        }
        
        Logger.shared.log("PDFAnnotationSync: Successfully wrote annotated PDF to \(destinationURL.path)", category: "PDF", type: .success)
        return destinationURL
    }
}

// MARK: - Asynchronous Background Disk Writer

private final class BackgroundWriteOperation: @unchecked Sendable {
    private static let serialQueue = DispatchQueue(label: "com.antigravity.InksyncPro.pdfDiskWriteQueue", qos: .utility)
    
    let document: PDFDocument
    let targetURL: URL
    let pdfID: UUID
    let didAccessSecurityScope: Bool
    var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init(document: PDFDocument, targetURL: URL, pdfID: UUID, didAccessSecurityScope: Bool) {
        self.document = document
        self.targetURL = targetURL
        self.pdfID = pdfID
        self.didAccessSecurityScope = didAccessSecurityScope
    }

    func start() {
        self.backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "InksyncPDFSync_\(pdfID.uuidString)") { [weak self] in
            self?.end()
        }

        Self.serialQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                if self.didAccessSecurityScope {
                    self.targetURL.stopAccessingSecurityScopedResource()
                }
                self.end()
            }

            let writeSuccess = self.document.write(to: self.targetURL)
            if writeSuccess {
                Logger.shared.log("PDFAnnotationSync: Persisted PDF with annotations to disk at \(self.targetURL.lastPathComponent)", category: "PDF", type: .success)
            } else {
                Logger.shared.log("PDFAnnotationSync: Background write failed for \(self.targetURL.lastPathComponent)", category: "PDF", type: .warning)
            }
        }
    }

    private func end() {
        DispatchQueue.main.async {
            guard self.backgroundTaskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
            self.backgroundTaskID = .invalid
        }
    }
}

// MARK: - Errors & Extensions

public enum PDFSyncError: LocalizedError, Sendable {
    case documentSerializationFailed
    case fileWriteFailed
    
    public var errorDescription: String? {
        switch self {
        case .documentSerializationFailed:
            return "Failed to serialize the PDF document into memory."
        case .fileWriteFailed:
            return "Failed to write the annotated PDF document to disk."
        }
    }
}

private extension UIColor {
    convenience init?(hexString: String) {
        let clean = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        guard Scanner(string: clean).scanHexInt64(&int) else { return nil }
        let r, g, b, a: CGFloat
        switch clean.count {
        case 3: // RGB (12-bit)
            (r, g, b, a) = (CGFloat((int >> 8) * 17) / 255, CGFloat((int >> 4 & 0xF) * 17) / 255, CGFloat((int & 0xF) * 17) / 255, 1)
        case 6: // RGB (24-bit)
            (r, g, b, a) = (CGFloat((int >> 16) & 0xFF) / 255, CGFloat((int >> 8) & 0xFF) / 255, CGFloat(int & 0xFF) / 255, 1)
        case 8: // ARGB (32-bit)
            (r, g, b, a) = (CGFloat((int >> 16) & 0xFF) / 255, CGFloat((int >> 8) & 0xFF) / 255, CGFloat(int & 0xFF) / 255, CGFloat((int >> 24) & 0xFF) / 255)
        default:
            return nil
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    func toHexString() -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else {
            var white: CGFloat = 0
            if getWhite(&white, alpha: &a) {
                let rgb = Int(white * 255)
                return String(format: "#%02x%02x%02x", rgb, rgb, rgb)
            }
            return "#FFD600"
        }
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

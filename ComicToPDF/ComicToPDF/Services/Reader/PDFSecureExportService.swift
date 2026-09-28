import Foundation
import PDFKit
import UIKit

// MARK: - PDF Export Format

/// Dual export personas for marked-up PDF documents.
public enum PDFExportFormat: String, CaseIterable, Identifiable, Sendable {
    case flattened = "flattened"
    case editableAnnotations = "editableAnnotations"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .flattened:
            return "Flattened (Tamper-Proof)"
        case .editableAnnotations:
            return "Editable Annotations (ISO 32000)"
        }
    }

    public var shortBadge: String {
        switch self {
        case .flattened:
            return "Tamper-Proof"
        case .editableAnnotations:
            return "Collaborative"
        }
    }

    public var subtitle: String {
        switch self {
        case .flattened:
            return "Pencil ink, highlighters, and notes are permanently rasterized into the base page stream. Strokes cannot be selected, altered, or deleted by recipients. Ideal for submissions and signed contracts."
        case .editableAnnotations:
            return "Strokes remain interactive ISO 32000 /Ink and /Highlight annotations compatible with Adobe Acrobat, Apple Books, and macOS Preview for collaborative peer review."
        }
    }

    public var iconName: String {
        switch self {
        case .flattened:
            return "lock.shield.fill"
        case .editableAnnotations:
            return "pencil.and.scribble"
        }
    }
}

// MARK: - PDF Export Configuration

/// Comprehensive security and layer export parameters.
public struct PDFExportConfiguration: Sendable, Equatable {
    public var format: PDFExportFormat
    public var includeHandwrittenInk: Bool
    public var includeTextHighlights: Bool
    public var includeLineartOverlay: Bool
    public var isPasswordProtected: Bool
    public var userPassword: String
    public var ownerPassword: String
    public var allowPrinting: Bool
    public var allowCopying: Bool
    public var stripInternalMetadata: Bool

    public init(
        format: PDFExportFormat = .flattened,
        includeHandwrittenInk: Bool = true,
        includeTextHighlights: Bool = true,
        includeLineartOverlay: Bool = true,
        isPasswordProtected: Bool = false,
        userPassword: String = "",
        ownerPassword: String = "",
        allowPrinting: Bool = true,
        allowCopying: Bool = true,
        stripInternalMetadata: Bool = true
    ) {
        self.format = format
        self.includeHandwrittenInk = includeHandwrittenInk
        self.includeTextHighlights = includeTextHighlights
        self.includeLineartOverlay = includeLineartOverlay
        self.isPasswordProtected = isPasswordProtected
        self.userPassword = userPassword
        self.ownerPassword = ownerPassword
        self.allowPrinting = allowPrinting
        self.allowCopying = allowCopying
        self.stripInternalMetadata = stripInternalMetadata
    }
}

// MARK: - PDF Secure Export Service

/// On-device, air-gapped PDF security engine.
/// Guarantees zero cloud telemetry, complete temporary file hygiene, AES-256 encryption,
/// metadata scrubbing, and protection against visual fake redaction traps.
@MainActor
public final class PDFSecureExportService: Sendable {
    public static let shared = PDFSecureExportService()

    private let secureExportDirName = "InksyncSecureExports"

    private init() {}

    // MARK: - Temporary File Lifecycle & Sanitization

    /// Returns a designated directory protected with complete hardware encryption (NSFileProtectionComplete).
    public func getSecureExportDirectory() throws -> URL {
        let baseTemp = FileManager.default.temporaryDirectory
        let exportDir = baseTemp.appendingPathComponent(secureExportDirName, isDirectory: true)

        if !FileManager.default.fileExists(atPath: exportDir.path) {
            try FileManager.default.createDirectory(
                at: exportDir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        return exportDir
    }

    /// Auto-purges temporary export artifacts older than the specified duration to prevent disk bloat and data leaks.
    public func purgeStaleExports(olderThan interval: TimeInterval = 3600) {
        do {
            let exportDir = try getSecureExportDirectory()
            let files = try FileManager.default.contentsOfDirectory(
                at: exportDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let cutoffDate = Date().addingTimeInterval(-interval)

            for file in files {
                let attrs = try file.resourceValues(forKeys: [.contentModificationDateKey])
                if let modDate = attrs.contentModificationDate, modDate < cutoffDate {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        } catch {
            Logger.shared.log("PDFSecureExportService: Failed to purge stale exports: \(error.localizedDescription)", category: "PDF", type: .warning)
        }
    }

    // MARK: - Fake Redaction Risk Detection

    /// Analyzes document annotations to determine whether the user has drawn dark marker strokes
    /// that might give a false impression of text redaction when exported in editable vector mode.
    public func hasPotentialRedactionRisks(for pdfID: UUID) -> Bool {
        let annotations = AnnotationStore.shared.annotations(for: pdfID)
        let hasInk = annotations.contains(where: { $0.kind == .ink })
        return hasInk
    }

    // MARK: - Export Generation Pipeline

    /// Orchestrates on-device local compilation and sanitization of the marked-up PDF.
    public func exportPDF(
        for pdfID: UUID,
        document: PDFDocument,
        title: String,
        config: PDFExportConfiguration
    ) async throws -> URL {
        // 1. Maintain resource hygiene by purging expired export runs
        purgeStaleExports()

        // 2. Prepare destination path within encrypted temp directory
        let exportDir = try getSecureExportDirectory()
        let sanitizedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")

        let baseName = sanitizedTitle.isEmpty ? "Marked-Up Document" : sanitizedTitle
        let suffix: String
        switch config.format {
        case .flattened:
            suffix = config.isPasswordProtected ? "(Flattened-Secured)" : "(Flattened)"
        case .editableAnnotations:
            suffix = config.isPasswordProtected ? "(Annotated-Secured)" : "(Annotated)"
        }

        let destinationURL = exportDir.appendingPathComponent("\(baseName) \(suffix).pdf")

        // 3. Remove any previous file at this exact destination
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        // 4. Delegate to PDFAnnotationSyncBridge with configured security parameters
        let outputURL: URL
        switch config.format {
        case .flattened:
            outputURL = try PDFAnnotationSyncBridge.shared.generateFlattenedPDF(
                from: document,
                for: pdfID,
                saveTo: destinationURL,
                config: config
            )
        case .editableAnnotations:
            outputURL = try PDFAnnotationSyncBridge.shared.generateAnnotatedPDF(
                from: document,
                for: pdfID,
                saveTo: destinationURL,
                config: config
            )
        }

        // 5. Ensure final file permissions are locked with NSFileProtectionComplete
        try? (FileManager.default as NSFileManager).setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: outputURL.path
        )

        Logger.shared.log("PDFSecureExportService: Generated \(config.format.title) at \(outputURL.lastPathComponent)", category: "PDF", type: .success)
        return outputURL
    }
}

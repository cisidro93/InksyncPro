import Foundation
import UIKit
import PDFKit
import ZIPFoundation

/// Standardized forensic diagnostic report for any document that fails to open.
struct DocumentDiagnosticReport: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let fileName: String
    let fileURL: URL
    let fileExtension: String
    let fileSizeBytes: Int64
    let formattedFileSize: String
    let fileExistsOnDisk: Bool
    let isSandboxURL: Bool
    let isSecurityScoped: Bool
    let securityScopeGranted: Bool
    let isDriveBookmarkStale: Bool
    let detectedFormat: String
    let magicBytesHex: String
    let isLockedOrEncrypted: Bool
    let context: String
    let rootCauseDescription: String
    let actionableRemediation: String
    let underlyingErrorDescription: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        fileName: String,
        fileURL: URL,
        fileExtension: String,
        fileSizeBytes: Int64,
        formattedFileSize: String,
        fileExistsOnDisk: Bool,
        isSandboxURL: Bool,
        isSecurityScoped: Bool,
        securityScopeGranted: Bool,
        isDriveBookmarkStale: Bool,
        detectedFormat: String,
        magicBytesHex: String,
        isLockedOrEncrypted: Bool,
        context: String,
        rootCauseDescription: String,
        actionableRemediation: String,
        underlyingErrorDescription: String?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.fileName = fileName
        self.fileURL = fileURL
        self.fileExtension = fileExtension
        self.fileSizeBytes = fileSizeBytes
        self.formattedFileSize = formattedFileSize
        self.fileExistsOnDisk = fileExistsOnDisk
        self.isSandboxURL = isSandboxURL
        self.isSecurityScoped = isSecurityScoped
        self.securityScopeGranted = securityScopeGranted
        self.isDriveBookmarkStale = isDriveBookmarkStale
        self.detectedFormat = detectedFormat
        self.magicBytesHex = magicBytesHex
        self.isLockedOrEncrypted = isLockedOrEncrypted
        self.context = context
        self.rootCauseDescription = rootCauseDescription
        self.actionableRemediation = actionableRemediation
        self.underlyingErrorDescription = underlyingErrorDescription
    }

    /// Full multi-line formatted string for flight recorder logs and clipboard export.
    var formattedLogString: String {
        let timeStr = DateFormatter.localizedString(from: timestamp, dateStyle: .short, timeStyle: .medium)
        var lines: [String] = []
        lines.append("══════════════════════════════════════════════════════════════════")
        lines.append("❌ DOCUMENT OPEN FAILURE REPORT [\(context.uppercased())]")
        lines.append("══════════════════════════════════════════════════════════════════")
        lines.append("• Timestamp:       \(timeStr)")
        lines.append("• Document Name:   \(fileName)")
        lines.append("• Path Extension:  .\(fileExtension.isEmpty ? "(none)" : fileExtension)")
        lines.append("• Resolved Path:   \(fileURL.path)")
        lines.append("• File Exists:     \(fileExistsOnDisk ? "YES" : "NO (Missing from Disk)")")
        lines.append("• File Size:       \(formattedFileSize) (\(fileSizeBytes) bytes)")
        lines.append("• Sandbox URL:     \(isSandboxURL ? "YES (App Container)" : "NO (External / Shared)")")
        lines.append("• Security-Scoped: \(isSecurityScoped ? (securityScopeGranted ? "YES (Access Granted)" : "YES (Access DENIED)") : "NO")")
        if isDriveBookmarkStale {
            lines.append("• Bookmark Status: ⚠️ STALE / EXPIRED (Drive disconnected or permission revoked)")
        }
        lines.append("• Detected Format: \(detectedFormat)")
        if !magicBytesHex.isEmpty {
            lines.append("• Magic Bytes:     \(magicBytesHex)")
        }
        if isLockedOrEncrypted {
            lines.append("• Encryption:      🔒 LOCKED / PASSWORD PROTECTED")
        }
        if let err = underlyingErrorDescription, !err.isEmpty {
            lines.append("• System Error:    \(err)")
        }
        lines.append("──────────────────────────────────────────────────────────────────")
        lines.append("🔍 ROOT CAUSE:")
        lines.append("  \(rootCauseDescription)")
        lines.append("──────────────────────────────────────────────────────────────────")
        lines.append("💡 REMEDIATION:")
        lines.append("  \(actionableRemediation)")
        lines.append("══════════════════════════════════════════════════════════════════")
        return lines.joined(separator: "\n")
    }

    /// Short single-sentence summary for inline HUD toasts.
    var condensedSummary: String {
        "Failed to open '\(fileName)': \(rootCauseDescription)"
    }
}

/// Centralized diagnostic engine for analyzing, classifying, and logging document opening failures.
enum DocumentOpenDiagnostics: Sendable {

    /// Performs deep forensic analysis of why a file failed to open.
    static func analyze(
        url: URL,
        pdf: ConvertedPDF? = nil,
        error: Error? = nil,
        context: String = "Reader"
    ) -> DocumentDiagnosticReport {
        let fileManager = FileManager.default
        let ext = url.pathExtension.lowercased()
        let filename = pdf?.name ?? url.lastPathComponent
        
        // 1. Check Security Scope & Sandbox
        let isSandbox = isSandboxURL(url)
        var isSecurityScoped = false
        var securityScopeGranted = false
        var isBookmarkStale = false
        
        if let sourceMode = pdf?.sourceMode {
            switch sourceMode {
            case .linked(let bookmarkData):
                isSecurityScoped = true
                var stale = false
                if let resolved = try? URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale) {
                    isBookmarkStale = stale
                    let access = resolved.startAccessingSecurityScopedResource()
                    securityScopeGranted = access
                    if access { resolved.stopAccessingSecurityScopedResource() }
                } else {
                    isBookmarkStale = true
                }
            case .cloud:
                isSecurityScoped = false
            case .local:
                isSecurityScoped = false
            }
        }
        
        // 2. Check File Existence & Attributes
        var fileExists = fileManager.fileExists(atPath: url.path)
        var fileSize: Int64 = 0
        var magicHex = ""
        var detectedFormat = "Unknown"
        var isLocked = false
        
        // If not found at direct path, check if sandbox resolution helps
        var activeURL = url
        if !fileExists {
            let sandboxCandidate = LibraryFileRecord.resolveSandboxURL(url.absoluteString)
            if fileManager.fileExists(atPath: sandboxCandidate.path) {
                activeURL = sandboxCandidate
                fileExists = true
            }
        }
        
        if fileExists {
            if let attrs = try? fileManager.attributesOfItem(atPath: activeURL.path),
               let size = attrs[.size] as? Int64 {
                fileSize = size
            }
            
            // Read magic bytes
            let (format, hex) = readMagicBytes(at: activeURL)
            detectedFormat = format
            magicHex = hex
            
            // Check PDF lock
            if detectedFormat == "PDF" || ext == "pdf" {
                if let doc = PDFDocument(url: activeURL), doc.isLocked {
                    isLocked = true
                }
            }
        }
        
        let formattedSize = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        
        // 3. Determine Root Cause and Remediation Advice
        let (rootCause, remediation) = determineRootCauseAndRemediation(
            fileExists: fileExists,
            fileSize: fileSize,
            ext: ext,
            detectedFormat: detectedFormat,
            isSecurityScoped: isSecurityScoped,
            securityScopeGranted: securityScopeGranted,
            isBookmarkStale: isBookmarkStale,
            isLocked: isLocked,
            underlyingError: error,
            activeURL: activeURL
        )
        
        return DocumentDiagnosticReport(
            fileName: filename,
            fileURL: activeURL,
            fileExtension: ext,
            fileSizeBytes: fileSize,
            formattedFileSize: formattedSize,
            fileExistsOnDisk: fileExists,
            isSandboxURL: isSandbox,
            isSecurityScoped: isSecurityScoped,
            securityScopeGranted: securityScopeGranted,
            isDriveBookmarkStale: isBookmarkStale,
            detectedFormat: detectedFormat,
            magicBytesHex: magicHex,
            isLockedOrEncrypted: isLocked,
            context: context,
            rootCauseDescription: rootCause,
            actionableRemediation: remediation,
            underlyingErrorDescription: error?.localizedDescription
        )
    }

    /// Analyzes the failure, logs the full diagnostic report to `Logger.shared` with `.error` level,
    /// and returns the structured report.
    @discardableResult
    static func logFailure(
        url: URL,
        pdf: ConvertedPDF? = nil,
        error: Error? = nil,
        context: String = "Reader"
    ) -> DocumentDiagnosticReport {
        let report = analyze(url: url, pdf: pdf, error: error, context: context)
        
        // Log to Flight Recorder with category "DocumentOpen" and type .error
        Logger.shared.log(
            report.formattedLogString,
            category: "DocumentOpen",
            type: .error
        )
        
        return report
    }

    // MARK: - Internal Helpers

    nonisolated private static func isSandboxURL(_ url: URL) -> Bool {
        let resolvedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let homePath = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.resolvingSymlinksInPath().path
        return resolvedPath.hasPrefix(homePath)
    }

    nonisolated private static func readMagicBytes(at url: URL) -> (format: String, hex: String) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ("Inaccessible", "")
        }
        defer { try? handle.close() }
        
        guard let data = try? handle.read(upToCount: 8), !data.isEmpty else {
            return ("Empty (0 bytes)", "")
        }
        
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let bytes = [UInt8](data)
        
        // PDF: %PDF- (0x25 0x50 0x44 0x46)
        if bytes.count >= 4 && bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46 {
            return ("PDF", hex)
        }
        // ZIP / CBZ / EPUB: PK\x03\x04 or PK\x05\x06 or PK\x07\x08
        if bytes.count >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07) {
            return ("ZIP/Archive", hex)
        }
        // RAR: Rar! (0x52 0x61 0x72 0x21)
        if bytes.count >= 4 && bytes[0] == 0x52 && bytes[1] == 0x61 && bytes[2] == 0x72 && bytes[3] == 0x21 {
            return ("RAR", hex)
        }
        // TAR: check header at offset 257 if file size >= 512, otherwise fallback
        if bytes.count >= 4 && bytes[0] == 0x75 && bytes[1] == 0x73 && bytes[2] == 0x74 && bytes[3] == 0x61 {
            return ("TAR", hex)
        }
        // 7-Zip: 7z\xBC\xAF\x27\x1C (0x37 0x7A 0xBC 0xAF)
        if bytes.count >= 4 && bytes[0] == 0x37 && bytes[1] == 0x7A && bytes[2] == 0xBC && bytes[3] == 0xAF {
            return ("7-Zip", hex)
        }
        // Plain text / HTML error response (e.g. <!DOCTYPE or <html)
        if let str = String(data: data, encoding: .utf8)?.lowercased(), str.contains("<!doc") || str.contains("<html") {
            return ("HTML/Web Page (Misnamed Extension)", hex)
        }
        
        return ("Unknown Binary", hex)
    }

    nonisolated private static func determineRootCauseAndRemediation(
        fileExists: Bool,
        fileSize: Int64,
        ext: String,
        detectedFormat: String,
        isSecurityScoped: Bool,
        securityScopeGranted: Bool,
        isBookmarkStale: Bool,
        isLocked: Bool,
        underlyingError: Error?,
        activeURL: URL
    ) -> (rootCause: String, remediation: String) {
        if !fileExists {
            if isSecurityScoped {
                return (
                    "The document is located on an external drive or cloud folder that is not connected or accessible.",
                    "Ensure the external USB-C drive / SD card is plugged in, or re-link the folder in Settings ➔ Linked Libraries."
                )
            } else {
                return (
                    "The physical file was removed or moved from the app's local sandbox storage at '\(activeURL.path)'.",
                    "Try re-importing the file via the '+' button in your Library or re-syncing from your original source."
                )
            }
        }
        
        if isBookmarkStale || (isSecurityScoped && !securityScopeGranted) {
            return (
                "The iOS security-scoped permission bookmark has expired or access was revoked by the system.",
                "Navigate to Settings ➔ Linked Libraries, tap on the linked drive/folder, and grant read permission again."
            )
        }
        
        if fileSize == 0 {
            return (
                "The file is empty (0 bytes). The download or transfer was aborted before completion.",
                "Delete the empty file from your library and re-download or re-transfer the complete file."
            )
        }
        
        if isLocked {
            return (
                "The document is encrypted with password protection and could not be unlocked.",
                "Enter the document password when prompted to view the contents."
            )
        }
        
        if detectedFormat == "HTML/Web Page (Misnamed Extension)" {
            return (
                "The file contains HTML web page data instead of a valid \(ext.uppercased()) document (often caused by saving a download portal web page instead of the actual file).",
                "Re-download the file from your provider, ensuring you download the direct document binary rather than the web preview."
            )
        }
        
        // Format mismatch check
        if ext == "pdf" && detectedFormat != "PDF" && detectedFormat != "Unknown Binary" {
            return (
                "File has a .pdf extension but binary header is '\(detectedFormat)' instead of standard '%PDF-'.",
                "Rename the file extension to match its true format or re-export the document as a standard PDF."
            )
        }
        
        if (ext == "epub" || ext == "cbz") && detectedFormat == "PDF" {
            return (
                "File has a .\(ext) extension but is actually a standard PDF binary.",
                "Change the file extension to .pdf or convert it using Inksync Pro's built-in converter."
            )
        }
        
        // Archive integrity check
        if ["epub", "cbz", "zip"].contains(ext) && detectedFormat == "ZIP/Archive" {
            if let archive = try? Archive(url: activeURL, accessMode: .read, pathEncoding: .utf8) {
                if ext == "epub" {
                    if archive["META-INF/container.xml"] == nil {
                        return (
                            "EPUB archive is missing mandatory 'META-INF/container.xml' root descriptor.",
                            "The EPUB file structure is corrupted. Repair the EPUB archive with Calibre or re-download it."
                        )
                    }
                } else if ext == "cbz" || ext == "zip" {
                    let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic"]
                    let hasImages = archive.contains { entry in
                        let name = (entry.path as NSString).lastPathComponent
                        guard !entry.path.contains("__MACOSX"), !name.hasPrefix("._"), !entry.path.hasSuffix("/") else { return false }
                        return imageExtensions.contains((name as NSString).pathExtension.lowercased())
                    }
                    if !hasImages {
                        return (
                            "The comic archive opened successfully but contains 0 readable image pages.",
                            "Check that the archive contains image files (.jpg, .png, .webp) rather than nested sub-archives or text files."
                        )
                    }
                }
            } else {
                return (
                    "The ZIP/EPUB archive header or central directory table is corrupted and cannot be decompressed.",
                    "The archive file appears damaged. Try re-compressing the source images or obtaining an uncorrupted copy."
                )
            }
        }
        
        if let err = underlyingError {
            return (
                "File read failed due to system I/O error: \(err.localizedDescription)",
                "Restart the app. If the issue persists, export logs from Flight Recorder (Settings ➔ Logs) to report the bug."
            )
        }
        
        return (
            "The document could not be rendered by the reader engine. File contents may be damaged or in an unsupported sub-format.",
            "Verify the file opens in the Files app or another reader, or export your Flight Recorder logs to support."
        )
    }
}

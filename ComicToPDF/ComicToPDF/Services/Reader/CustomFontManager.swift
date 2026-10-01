import Foundation
import SwiftUI
import CoreText
import UniformTypeIdentifiers
import os

// ============================================================
// MARK: - Custom Downloaded Font Model
// ============================================================

struct CustomDownloadedFont: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let displayName: String
    let postScriptName: String
    let familyName: String
    let fileName: String
    let dateAdded: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        postScriptName: String,
        familyName: String,
        fileName: String,
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.postScriptName = postScriptName
        self.familyName = familyName
        self.fileName = fileName
        self.dateAdded = dateAdded
    }
}

// ============================================================
// MARK: - Custom Font Manager
// ============================================================

@MainActor
final class CustomFontManager: ObservableObject {
    static let shared = CustomFontManager()

    private static let logger = os.Logger(subsystem: "com.inksync.typography", category: "CustomFonts")
    private let userDefaultsKey = "InksyncPro_installedCustomFonts_v1"

    @Published private(set) var installedFonts: [CustomDownloadedFont] = []

    private var fontsDirectory: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("CustomFonts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {
        loadSavedFonts()
        registerInstalledFonts()
    }

    // MARK: - Persistence & Loading

    private func loadSavedFonts() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([CustomDownloadedFont].self, from: data) {
            self.installedFonts = decoded
        }
    }

    private func saveFonts() {
        if let encoded = try? JSONEncoder().encode(installedFonts) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
        NotificationCenter.default.post(name: NSNotification.Name("InksyncPro.customFontsChanged"), object: nil)
    }

    // MARK: - CoreText Dynamic Registration

    func registerInstalledFonts() {
        for font in installedFonts {
            let fileURL = fontsDirectory.appendingPathComponent(font.fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                Self.logger.warning("Custom font file missing on disk: \(fileURL.path)")
                continue
            }
            registerFontFile(at: fileURL)
        }
    }

    @discardableResult
    private func registerFontFile(at fileURL: URL) -> Bool {
        var error: Unmanaged<CFError>?
        let success = CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &error)
        if !success, let err = error?.takeRetainedValue() {
            let desc = CFErrorCopyDescription(err) as String? ?? "Unknown CoreText error"
            // If already registered, it's safe to continue
            if desc.contains("already registered") || (desc as NSString).range(of: "already", options: .caseInsensitive).location != NSNotFound {
                Self.logger.info("Custom font already registered in process: \(fileURL.lastPathComponent)")
                return true
            }
            Self.logger.warning("CoreText font registration notice for \(fileURL.lastPathComponent): \(desc)")
        } else {
            Self.logger.info("Successfully registered custom font via CoreText: \(fileURL.lastPathComponent)")
        }
        return success
    }

    // MARK: - Font Import

    func importFont(from sourceURL: URL) async throws -> CustomDownloadedFont {
        let isSecurityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fontData = try Data(contentsOf: sourceURL)
        guard let dataProvider = CGDataProvider(data: fontData as CFData),
              let cgFont = CGFont(dataProvider) else {
            throw NSError(
                domain: "com.inksync.typography",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid font file. InksyncPro could not parse font glyph tables."]
            )
        }

        let postScriptName = (cgFont.postScriptName as String?) ?? sourceURL.deletingPathExtension().lastPathComponent
        let fullName = (cgFont.fullName as String?) ?? postScriptName
        let ext = sourceURL.pathExtension.isEmpty ? "ttf" : sourceURL.pathExtension.lowercased()
        let uniqueFileName = "\(UUID().uuidString).\(ext)"
        let destinationURL = fontsDirectory.appendingPathComponent(uniqueFileName)

        try fontData.write(to: destinationURL, options: .atomic)

        // Register dynamically with CoreText
        registerFontFile(at: destinationURL)

        let newFont = CustomDownloadedFont(
            displayName: fullName,
            postScriptName: postScriptName,
            familyName: fullName,
            fileName: uniqueFileName
        )

        // Deduplicate by postScriptName
        installedFonts.removeAll { $0.postScriptName == postScriptName }
        installedFonts.append(newFont)
        saveFonts()

        Self.logger.info("Imported and activated custom font: '\(fullName)' (\(postScriptName))")
        return newFont
    }

    // MARK: - Font Deletion

    func deleteFont(_ font: CustomDownloadedFont) {
        let fileURL = fontsDirectory.appendingPathComponent(font.fileName)
        var error: Unmanaged<CFError>?
        CTFontManagerUnregisterFontsForURL(fileURL as CFURL, .process, &error)

        try? FileManager.default.removeItem(at: fileURL)
        installedFonts.removeAll { $0.id == font.id }
        saveFonts()

        // If the deleted font was active in EBookPreferences, revert to default
        if EBookPreferences.shared.fontFamily.contains(font.postScriptName) {
            EBookPreferences.shared.fontFamily = EBookFontFamily.newYork.rawValue
        }

        Self.logger.info("Unregistered and deleted custom font: '\(font.displayName)'")
    }

    // MARK: - CSS @font-face Generation for WKWebView / EPUB

    func generateCSSRules() -> String {
        guard !installedFonts.isEmpty else { return "" }
        var css = "\n/* Custom Downloaded Fonts */\n"
        for font in installedFonts {
            css += """
            @font-face {
                font-family: '\(font.postScriptName)';
                src: local('\(font.postScriptName)'), local('\(font.familyName)'), local('\(font.displayName)');
                font-weight: normal;
                font-style: normal;
            }
            """
        }
        return css
    }
}

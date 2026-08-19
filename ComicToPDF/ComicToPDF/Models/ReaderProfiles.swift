import Foundation
import UIKit
import SwiftUI

// MARK: - Layout & Ergonomic Enums

public enum ParagraphLayoutMode: String, Codable, Sendable, CaseIterable {
    case traditionalIndent  // text-indent: 1.5em; margin-bottom: 0
    case modernBlock        // text-indent: 0; margin-bottom: 0.8em
    
    public var label: String {
        switch self {
        case .traditionalIndent: return "Traditional Indent"
        case .modernBlock:       return "Modern Block"
        }
    }
}

public enum TextAlignmentMode: String, Codable, Sendable, CaseIterable {
    case left      = "left"
    case justified = "justify"
    case center    = "center"
    
    public var label: String {
        switch self {
        case .left:      return "Left"
        case .justified: return "Justified"
        case .center:    return "Center"
        }
    }
}

public enum TapZonePreset: String, Codable, Sendable, CaseIterable {
    case standard       = "standard"
    case oneHandedRight = "oneHandedRight"
    case oneHandedLeft  = "oneHandedLeft"
    
    public var label: String {
        switch self {
        case .standard:       return "Standard (30 / 40 / 30)"
        case .oneHandedRight: return "One-Handed Right (Right Dominant)"
        case .oneHandedLeft:  return "One-Handed Left (Left Dominant)"
        }
    }
}

public enum PencilAction: String, Codable, Sendable, CaseIterable {
    case nextPage
    case toggleGuidedView
    case openStudyDrawer
    case toggleInkBoost
    
    public var label: String {
        switch self {
        case .nextPage:          return "Turn to Next Page"
        case .toggleGuidedView:  return "Toggle Guided View"
        case .openStudyDrawer:   return "Open Study Notebook"
        case .toggleInkBoost:    return "Toggle Ink Boost"
        }
    }
}

public enum ReadingDirection: String, Codable, Sendable, CaseIterable {
    case leftToRight = "ltr"
    case rightToLeft = "rtl"
    
    public var label: String {
        switch self {
        case .leftToRight: return "Left to Right (Western)"
        case .rightToLeft: return "Right to Left (Manga)"
        }
    }
}

// MARK: - Codable Edge Insets Helper

public struct CodableEdgeInsets: Codable, Sendable, Equatable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat
    
    public static let zero = CodableEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    
    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
    
    public init(_ insets: UIEdgeInsets) {
        self.top = insets.top
        self.left = insets.left
        self.bottom = insets.bottom
        self.right = insets.right
    }
    
    public var uiEdgeInsets: UIEdgeInsets {
        UIEdgeInsets(top: top, left: left, bottom: bottom, right: right)
    }
}

// MARK: - Book Display Profile (KOReader-Grade Typography & Layout Overrides)

public struct BookDisplayProfile: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var documentID: UUID
    
    // Core Layout
    public var fontFamily: String
    public var fontSizePoints: CGFloat
    public var lineSpacingMultiplier: Double
    public var paragraphSpacingMode: ParagraphLayoutMode // .indented vs .blockSpacing
    public var textAlignment: TextAlignmentMode          // .left vs .justified
    public var isHyphenationEnabled: Bool
    
    // KOReader-Grade Overrides
    public var ignorePublisherCSS: Bool                  // Force strip hardcoded styles
    public var fontWeightOffset: Double                  // Optical weight adjustment (-1.0 to 2.0)
    public var contrastBoost: Double                     // Image & scan gamma adjustment
    public var customMarginInsets: CodableEdgeInsets     // Granular top/bottom/left/right insets
    
    // Ergonomics & Gestures
    public var tapZoneConfiguration: TapZonePreset       // .standard, .oneHandedRight, .oneHandedLeft
    
    public init(
        id: UUID = UUID(),
        documentID: UUID,
        fontFamily: String = "New York",
        fontSizePoints: CGFloat = 18.0,
        lineSpacingMultiplier: Double = 1.5,
        paragraphSpacingMode: ParagraphLayoutMode = .traditionalIndent,
        textAlignment: TextAlignmentMode = .justified,
        isHyphenationEnabled: Bool = true,
        ignorePublisherCSS: Bool = false,
        fontWeightOffset: Double = 0.0,
        contrastBoost: Double = 1.0,
        customMarginInsets: CodableEdgeInsets = CodableEdgeInsets(top: 24, left: 24, bottom: 24, right: 24),
        tapZoneConfiguration: TapZonePreset = .standard
    ) {
        self.id = id
        self.documentID = documentID
        self.fontFamily = fontFamily
        self.fontSizePoints = fontSizePoints
        self.lineSpacingMultiplier = lineSpacingMultiplier
        self.paragraphSpacingMode = paragraphSpacingMode
        self.textAlignment = textAlignment
        self.isHyphenationEnabled = isHyphenationEnabled
        self.ignorePublisherCSS = ignorePublisherCSS
        self.fontWeightOffset = fontWeightOffset
        self.contrastBoost = contrastBoost
        self.customMarginInsets = customMarginInsets
        self.tapZoneConfiguration = tapZoneConfiguration
    }
}

// MARK: - Comic Customization Profile (Metal Shaders, Cropping & Hardware Mappings)

public struct ComicCustomizationProfile: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var seriesID: String
    
    // Image Enhancements (Metal Shaders)
    public var inkBoostIntensity: Double          // 0.0 to 1.0 (Deepen black inks)
    public var sharpeningStrength: Double         // 0.0 to 1.0 (Crisp linework)
    public var paperBleachThreshold: Double       // 0.0 to 1.0 (Remove yellow newsprint)
    public var isOLEDMarginsEnabled: Bool         // Pure #000000 letterbox borders
    
    // Layout & Cropping
    public var autoCropMargins: Bool              // Smart margin removal
    public var manualCropInsets: CodableEdgeInsets // Explicit top/bottom/left/right trim
    public var splitLandscapeSpreads: Bool        // Split wide spreads on portrait screens
    public var readingDirection: ReadingDirection // .leftToRight vs .rightToLeft
    
    // Hardware & Ergonomics
    public var enableVolumeKeyTurning: Bool       // Map hardware buttons
    public var applePencilDoubleTapAction: PencilAction // .toggleGuidedView, .openStudyDrawer
    
    public init(
        id: UUID = UUID(),
        seriesID: String,
        inkBoostIntensity: Double = 0.5,
        sharpeningStrength: Double = 0.0,
        paperBleachThreshold: Double = 0.15,
        isOLEDMarginsEnabled: Bool = true,
        autoCropMargins: Bool = false,
        manualCropInsets: CodableEdgeInsets = .zero,
        splitLandscapeSpreads: Bool = true,
        readingDirection: ReadingDirection = .leftToRight,
        enableVolumeKeyTurning: Bool = true,
        applePencilDoubleTapAction: PencilAction = .openStudyDrawer
    ) {
        self.id = id
        self.seriesID = seriesID
        self.inkBoostIntensity = inkBoostIntensity
        self.sharpeningStrength = sharpeningStrength
        self.paperBleachThreshold = paperBleachThreshold
        self.isOLEDMarginsEnabled = isOLEDMarginsEnabled
        self.autoCropMargins = autoCropMargins
        self.manualCropInsets = manualCropInsets
        self.splitLandscapeSpreads = splitLandscapeSpreads
        self.readingDirection = readingDirection
        self.enableVolumeKeyTurning = enableVolumeKeyTurning
        self.applePencilDoubleTapAction = applePencilDoubleTapAction
    }
}

// MARK: - Reader Profile Store

/// Authoritative `@MainActor` state manager persisting granular per-document and per-series reading customization profiles.
@MainActor
public final class ReaderProfileStore: ObservableObject {
    public static let shared = ReaderProfileStore()
    
    @AppStorage("reader_bookProfiles") private var bookProfilesData: Data = Data()
    @AppStorage("reader_comicProfiles") private var comicProfilesData: Data = Data()
    
    private var bookProfilesCache: [UUID: BookDisplayProfile] = [:]
    private var comicProfilesCache: [String: ComicCustomizationProfile] = [:]
    
    private init() {
        loadProfiles()
    }
    
    // MARK: - Book Display Profiles API
    
    public func profile(for documentID: UUID) -> BookDisplayProfile {
        if let cached = bookProfilesCache[documentID] {
            return cached
        }
        let newProfile = BookDisplayProfile(documentID: documentID)
        bookProfilesCache[documentID] = newProfile
        saveBookProfiles()
        return newProfile
    }
    
    public func saveProfile(_ profile: BookDisplayProfile) {
        bookProfilesCache[profile.documentID] = profile
        saveBookProfiles()
        objectWillChange.send()
    }
    
    // MARK: - Comic Customization Profiles API
    
    public func comicProfile(for seriesID: String) -> ComicCustomizationProfile {
        if let cached = comicProfilesCache[seriesID] {
            return cached
        }
        let newProfile = ComicCustomizationProfile(seriesID: seriesID)
        comicProfilesCache[seriesID] = newProfile
        saveComicProfiles()
        return newProfile
    }
    
    public func saveComicProfile(_ profile: ComicCustomizationProfile) {
        comicProfilesCache[profile.seriesID] = profile
        saveComicProfiles()
        objectWillChange.send()
    }
    
    // MARK: - Persistence
    
    private func loadProfiles() {
        if let decodedBooks = try? JSONDecoder().decode([UUID: BookDisplayProfile].self, from: bookProfilesData) {
            self.bookProfilesCache = decodedBooks
        }
        if let decodedComics = try? JSONDecoder().decode([String: ComicCustomizationProfile].self, from: comicProfilesData) {
            self.comicProfilesCache = decodedComics
        }
    }
    
    private func saveBookProfiles() {
        if let encoded = try? JSONEncoder().encode(bookProfilesCache) {
            self.bookProfilesData = encoded
        }
    }
    
    private func saveComicProfiles() {
        if let encoded = try? JSONEncoder().encode(comicProfilesCache) {
            self.comicProfilesData = encoded
        }
    }
}

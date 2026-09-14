import SwiftUI
import PencilKit

// MARK: - Inksync Inking Tool Types

public enum InkingToolKind: String, Codable, CaseIterable, Sendable {
    case fountainPen = "fountainPen"
    case fineliner   = "fineliner"
    case highlighter = "highlighter"
    case calligraphy = "calligraphy"
    case watercolor  = "watercolor"
    case crayon      = "crayon"
    case pencil      = "pencil"
    case eraser      = "eraser"

    public var displayName: String {
        switch self {
        case .fountainPen: return "Fountain Pen"
        case .fineliner:   return "Fineliner"
        case .highlighter: return "Smart Highlighter"
        case .calligraphy: return "Calligraphy Brush"
        case .watercolor:  return "Watercolor"
        case .crayon:      return "Crayon"
        case .pencil:      return "Colored Pencil"
        case .eraser:      return "Precision Eraser"
        }
    }

    public var iconSystemName: String {
        switch self {
        case .fountainPen: return "pencil.tip"
        case .fineliner:   return "pencil.line"
        case .highlighter: return "highlighter"
        case .calligraphy: return "paintbrush.pointed"
        case .watercolor:  return "drop.fill"
        case .crayon:      return "paintbrush"
        case .pencil:      return "pencil"
        case .eraser:      return "eraser.fill"
        }
    }
}

// MARK: - Calibrated Palette & Digital Coloring Studio 20-Color Array

public enum InksyncInkColor: String, Codable, CaseIterable, Sendable {
    case obsidian    = "#000000"
    case charcoal    = "#3A3A3C"
    case slate       = "#8E8E93"
    case cobalt      = "#0A84FF"
    case crimson     = "#FF453A"
    case emerald     = "#30D158"
    case honeyYellow = "#FFD60A"
    case violet      = "#BF5AF2"
    case sepia       = "#AC8E68"

    // Digital Coloring Studio Vibrant Additions
    case tangerine   = "#FF9500"
    case coral       = "#FF6B6B"
    case bubblegum   = "#FF2D55"
    case lilac       = "#AF52DE"
    case skyBlue     = "#5AC8FA"
    case oceanTeal   = "#30B0C7"
    case mint        = "#00C7BE"
    case lime        = "#34C759"
    case peach       = "#FFD1B3"
    case warmBrown   = "#8B572A"
    case pureWhite   = "#FFFFFF"

    public var displayName: String {
        switch self {
        case .obsidian:    return "Black"
        case .charcoal:    return "Charcoal"
        case .slate:       return "Gray"
        case .cobalt:      return "Cobalt"
        case .crimson:     return "Crimson"
        case .emerald:     return "Emerald"
        case .honeyYellow: return "Honey Yellow"
        case .violet:      return "Violet"
        case .sepia:       return "Sepia"
        case .tangerine:   return "Tangerine"
        case .coral:       return "Coral"
        case .bubblegum:   return "Bubblegum"
        case .lilac:       return "Lilac"
        case .skyBlue:     return "Sky Blue"
        case .oceanTeal:   return "Ocean Teal"
        case .mint:        return "Mint"
        case .lime:        return "Lime"
        case .peach:       return "Peach"
        case .warmBrown:   return "Brown"
        case .pureWhite:   return "White"
        }
    }

    public var color: Color {
        Color(hex: self.rawValue)
    }

    public var uiColor: UIColor {
        switch self {
        case .obsidian:    return UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        case .charcoal:    return UIColor(red: 0.227, green: 0.227, blue: 0.235, alpha: 1.0)
        case .slate:       return UIColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1.0)
        case .cobalt:      return UIColor(red: 0.039, green: 0.518, blue: 1.0, alpha: 1.0)
        case .crimson:     return UIColor(red: 1.0, green: 0.271, blue: 0.227, alpha: 1.0)
        case .emerald:     return UIColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1.0)
        case .honeyYellow: return UIColor(red: 1.0, green: 0.839, blue: 0.039, alpha: 1.0)
        case .violet:      return UIColor(red: 0.749, green: 0.353, blue: 0.949, alpha: 1.0)
        case .sepia:       return UIColor(red: 0.675, green: 0.557, blue: 0.408, alpha: 1.0)
        case .tangerine:   return UIColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1.0)
        case .coral:       return UIColor(red: 1.0, green: 0.420, blue: 0.420, alpha: 1.0)
        case .bubblegum:   return UIColor(red: 1.0, green: 0.176, blue: 0.333, alpha: 1.0)
        case .lilac:       return UIColor(red: 0.686, green: 0.322, blue: 0.871, alpha: 1.0)
        case .skyBlue:     return UIColor(red: 0.353, green: 0.784, blue: 0.980, alpha: 1.0)
        case .oceanTeal:   return UIColor(red: 0.188, green: 0.690, blue: 0.780, alpha: 1.0)
        case .mint:        return UIColor(red: 0.0, green: 0.780, blue: 0.745, alpha: 1.0)
        case .lime:        return UIColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 1.0)
        case .peach:       return UIColor(red: 1.0, green: 0.820, blue: 0.702, alpha: 1.0)
        case .warmBrown:   return UIColor(red: 0.545, green: 0.341, blue: 0.165, alpha: 1.0)
        case .pureWhite:   return UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        }
    }
}

// MARK: - Inking Tool Preset

public struct InkingToolPreset: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: InkingToolKind
    public var color: InksyncInkColor
    public var width: CGFloat

    public init(id: UUID = UUID(), name: String, kind: InkingToolKind, color: InksyncInkColor, width: CGFloat) {
        self.id = id
        self.name = name
        self.kind = kind
        self.color = color
        self.width = width
    }
}

// MARK: - Kindle-Style Reader Tool Mode

public enum ReaderToolMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case write          // Freehand Pencil / Ink writing (PKCanvasView)
    case textHighlight  // Digital text highlight glide (snaps to words)
    case eraser         // Precision / stroke eraser (PKCanvasView)
    case read           // Pure reading / navigation mode (no inking, no text selection)

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .write: return "Pen"
        case .textHighlight: return "Highlight"
        case .eraser: return "Eraser"
        case .read: return "Read"
        }
    }

    public var iconSystemName: String {
        switch self {
        case .write: return "pencil.tip"
        case .textHighlight: return "highlighter"
        case .eraser: return "eraser.fill"
        case .read: return "hand.point.up.left"
        }
    }
}

// MARK: - Inksync Inking State Manager

@MainActor
public final class InksyncInkingState: ObservableObject {
    public static let shared = InksyncInkingState()

    @Published public var activePreset: InkingToolPreset {
        didSet { saveSettings() }
    }

    @Published public var favorites: [InkingToolPreset] {
        didSet { saveSettings() }
    }

    @Published public var activeToolMode: ReaderToolMode = .write {
        didSet {
            if activeToolMode == .eraser && activePreset.kind != .eraser {
                toggleEraser()
            } else if activeToolMode == .write && activePreset.kind == .eraser {
                toggleEraser()
            }
            saveSettings()
        }
    }

    @Published public var isDockVisible: Bool = true
    @Published public var dockEdge: InksyncDockEdge = .bottom
    @Published public var eraserType: PKEraserTool.EraserType = .vector

    /// Digital Coloring Studio Mode: activates transparent lineart preservation
    /// and expands the inking toolbar to full artist palette + artist inking tools.
    @Published public var isColoringModeActive: Bool = false {
        didSet {
            saveSettings()
            NotificationCenter.default.post(name: NSNotification.Name("InksyncColoringModeChanged"), object: isColoringModeActive)
        }
    }

    public enum InksyncDockEdge: String, Codable, Sendable {
        case top, bottom, leading, trailing
    }

    private init() {
        let defaultP1 = InkingToolPreset(name: "Black Fine", kind: .fineliner, color: .obsidian, width: 1.5)
        let defaultP2 = InkingToolPreset(name: "Cobalt Pen", kind: .fountainPen, color: .cobalt, width: 2.2)
        let defaultP3 = InkingToolPreset(name: "Crimson Critic", kind: .fineliner, color: .crimson, width: 1.8)
        let defaultP4 = InkingToolPreset(name: "Studio Brush", kind: .calligraphy, color: .obsidian, width: 3.5)

        self.favorites = [defaultP1, defaultP2, defaultP3, defaultP4]
        self.activePreset = defaultP1

        loadSettings()
    }

    public func selectFavorite(at index: Int) {
        guard favorites.indices.contains(index) else { return }
        activePreset = favorites[index]
        if activePreset.kind == .eraser {
            activeToolMode = .eraser
        } else {
            activeToolMode = .write
        }
    }

    public func updateActiveColor(_ newColor: InksyncInkColor) {
        activePreset.color = newColor
        syncActiveWithFavorites()
    }

    public func updateActiveWidth(_ newWidth: CGFloat) {
        activePreset.width = max(0.5, min(36.0, newWidth))
        syncActiveWithFavorites()
    }

    public func updateActiveKind(_ newKind: InkingToolKind) {
        activePreset.kind = newKind
        if newKind == .highlighter && activePreset.width < 10.0 {
            activePreset.width = 18.0
        } else if newKind == .watercolor && activePreset.width < 12.0 {
            activePreset.width = 20.0
        } else if newKind == .crayon && activePreset.width < 8.0 {
            activePreset.width = 14.0
        } else if newKind == .pencil && activePreset.width > 6.0 {
            activePreset.width = 2.5
        } else if newKind != .highlighter && newKind != .watercolor && newKind != .crayon && activePreset.width > 8.0 {
            activePreset.width = 2.0
        }
        if newKind == .eraser {
            activeToolMode = .eraser
        } else {
            activeToolMode = .write
        }
        syncActiveWithFavorites()
    }

    public func toggleEraser() {
        if activePreset.kind == .eraser {
            // Restore first non-eraser favorite
            activePreset = favorites.first(where: { $0.kind != .eraser }) ?? favorites[0]
            if activeToolMode == .eraser {
                activeToolMode = .write
            }
        } else {
            activePreset = InkingToolPreset(name: "Eraser", kind: .eraser, color: .charcoal, width: 10.0)
            if activeToolMode != .eraser {
                activeToolMode = .eraser
            }
        }
    }

    private func syncActiveWithFavorites() {
        if let idx = favorites.firstIndex(where: { $0.id == activePreset.id }) {
            favorites[idx] = activePreset
        }
    }

    public func makePKTool() -> PKTool {
        switch activePreset.kind {
        case .fountainPen:
            return PKInkingTool(.pen, color: activePreset.color.uiColor, width: activePreset.width)
        case .fineliner:
            return PKInkingTool(.monoline, color: activePreset.color.uiColor, width: activePreset.width)
        case .highlighter:
            return PKInkingTool(.marker, color: activePreset.color.uiColor, width: activePreset.width)
        case .calligraphy:
            return PKInkingTool(.pen, color: activePreset.color.uiColor, width: activePreset.width)
        case .watercolor:
            if #available(iOS 17.0, *) {
                return PKInkingTool(.watercolor, color: activePreset.color.uiColor, width: activePreset.width)
            } else {
                return PKInkingTool(.marker, color: activePreset.color.uiColor.withAlphaComponent(0.6), width: activePreset.width)
            }
        case .crayon:
            if #available(iOS 17.0, *) {
                return PKInkingTool(.crayon, color: activePreset.color.uiColor, width: activePreset.width)
            } else {
                return PKInkingTool(.pencil, color: activePreset.color.uiColor, width: activePreset.width)
            }
        case .pencil:
            return PKInkingTool(.pencil, color: activePreset.color.uiColor, width: activePreset.width)
        case .eraser:
            return PKEraserTool(eraserType)
        }
    }

    // MARK: - Persistence

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: "Inksync_InkingFavorites_v1")
        }
        if let activeData = try? JSONEncoder().encode(activePreset) {
            UserDefaults.standard.set(activeData, forKey: "Inksync_ActiveInkingPreset_v1")
        }
        UserDefaults.standard.set(dockEdge.rawValue, forKey: "Inksync_DockEdge_v1")
        UserDefaults.standard.set(isColoringModeActive, forKey: "Inksync_ColoringMode_v1")
    }

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "Inksync_InkingFavorites_v1"),
           let loaded = try? JSONDecoder().decode([InkingToolPreset].self, from: data),
           loaded.count == 4 {
            self.favorites = loaded.map { preset in
                if preset.kind == .highlighter {
                    return InkingToolPreset(name: "Studio Brush", kind: .calligraphy, color: preset.color == .honeyYellow ? .obsidian : preset.color, width: 3.5)
                }
                return preset
            }
        }
        if let activeData = UserDefaults.standard.data(forKey: "Inksync_ActiveInkingPreset_v1"),
           let loadedActive = try? JSONDecoder().decode(InkingToolPreset.self, from: activeData) {
            if loadedActive.kind == .highlighter {
                self.activePreset = InkingToolPreset(name: "Studio Brush", kind: .calligraphy, color: .obsidian, width: 3.5)
            } else {
                self.activePreset = loadedActive
            }
        }
        if let edgeRaw = UserDefaults.standard.string(forKey: "Inksync_DockEdge_v1"),
           let edge = InksyncDockEdge(rawValue: edgeRaw) {
            self.dockEdge = edge
        }
        self.isColoringModeActive = UserDefaults.standard.bool(forKey: "Inksync_ColoringMode_v1")
    }
}

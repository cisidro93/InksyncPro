import SwiftUI

extension Color {
    static let inkBackground = Color(hex: "#09090f")
    static let inkSurface = Color(hex: "#111118")
    static let inkSurfaceRaised = Color(hex: "#1a1a28")
    static let inkBorderSubtle = Color(hex: "#1e1e30")
    static let inkBorderVisible = Color(hex: "#2a2a45")
    static let inkTextPrimary = Color(hex: "#e8e8f5")
    static let inkTextSecondary = Color(hex: "#7070a0")
    static let inkTextTertiary = Color(hex: "#40405a")
    static let inkBlue = Color(hex: "#3d6fff")
    static let inkViolet = Color(hex: "#8b5cf6")
    static let inkAmber = Color(hex: "#f5a623")
    static let inkGreen = Color(hex: "#2dd4a0")
    static let inkRed = Color(hex: "#ff4d6d")

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

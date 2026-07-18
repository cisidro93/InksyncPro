import SwiftUI

/// Utility to calculate relative luminance and verify WCAG2-compliant contrast ratios
public struct ColorContrastCalculator {
    
    public static func getLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linearize(_ val: Double) -> Double {
            return val <= 0.03928 ? val / 12.92 : pow((val + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }
    
    public static func getLuminance(from hex: String) -> Double {
        guard let rgb = parseHex(hex) else { return 0.0 }
        return getLuminance(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
    
    public static func getContrastRatio(hex1: String, hex2: String) -> Double {
        let lum1 = getLuminance(from: hex1)
        let lum2 = getLuminance(from: hex2)
        let lighter = max(lum1, lum2)
        let darker = min(lum1, lum2)
        return (lighter + 0.05) / (darker + 0.05)
    }
    
    /// Validates background/text color contrast and adjusts text hex to maintain at least 4.5:1 ratio if needed
    public static func getLegibleTextColor(textHex: String, bgHex: String) -> String {
        let ratio = getContrastRatio(hex1: textHex, hex2: bgHex)
        if ratio >= 4.5 {
            return textHex
        }
        
        let bgLum = getLuminance(from: bgHex)
        if bgLum < 0.5 {
            return "#FFFFFF"
        } else {
            return "#000000"
        }
    }
    
    private static func parseHex(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") {
            cleaned.remove(at: cleaned.startIndex)
        }
        
        guard cleaned.count == 6 else { return nil }
        
        var rgbValue: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgbValue)
        
        let r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = Double(rgbValue & 0x0000FF) / 255.0
        
        return (r, g, b)
    }
}

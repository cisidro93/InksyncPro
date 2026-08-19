import SwiftUI
import CoreImage
import UIKit

// MARK: - Intelligent Dark Mode Engine

/// Hardware-accelerated color shader engine converting PDF paper white to OLED dark mode
/// while preserving the natural color, saturation, and chroma of embedded photos, diagrams, and charts.
public struct PDFIntelligentDarkModeModifier: ViewModifier {
    let isEnabled: Bool
    
    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }
    
    public func body(content: Content) -> some View {
        if isEnabled {
            if #available(iOS 17.0, *) {
                // Metal Shader Pipeline
                content
                    .colorEffect(ShaderLibrary.pdfIntelligentDarkMode())
            } else {
                // Fallback CoreImage Inversion with Hue Preservation
                content
                    .colorInvert()
                    .hueRotation(.degrees(180))
            }
        } else {
            content
        }
    }
}

public extension View {
    /// Applies intelligent luminance-preserving dark mode to the PDF reader canvas.
    func intelligentPDFDarkMode(isEnabled: Bool) -> some View {
        self.modifier(PDFIntelligentDarkModeModifier(isEnabled: isEnabled))
    }
}

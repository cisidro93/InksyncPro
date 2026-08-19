#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - Intelligent Dark Mode PDF Shader
// Converts paper white backgrounds to deep OLED dark surfaces and text to crisp off-white,
// while preserving the true hue, saturation, and chroma of embedded photos, diagrams, and colored charts.

[[ stitchable ]] half4 pdfIntelligentDarkMode(float2 position, half4 color) {
    half3 rgb = color.rgb;
    
    // Perceptual luminance calculation (ITU-R BT.709 standard)
    half lum = dot(rgb, half3(0.2126h, 0.7152h, 0.0722h));
    
    // Color saturation metric
    half maxC = max(rgb.r, max(rgb.g, rgb.b));
    half minC = min(rgb.r, min(rgb.g, rgb.b));
    half sat = (maxC > 0.001h) ? (maxC - minC) / maxC : 0.0h;
    
    // 1. If pixel has significant color saturation (figures, charts, illustrations), preserve true colors
    if (sat > 0.25h) {
        return color;
    }
    
    // 2. Paper White (lum > 0.80) -> Invert to dark gray / OLED dark background (#101016)
    if (lum > 0.80h) {
        half t = clamp((lum - 0.80h) / 0.20h, 0.0h, 1.0h);
        half targetLum = mix(0.14h, 0.06h, t);
        return half4(half3(targetLum), color.a);
    }
    
    // 3. Black / Dark Text (lum < 0.22) -> Invert to high-contrast off-white (#E5E5F0)
    if (lum < 0.22h) {
        half t = clamp(lum / 0.22h, 0.0h, 1.0h);
        half targetLum = mix(0.92h, 0.78h, t);
        return half4(half3(targetLum), color.a);
    }
    
    // 4. Monochrome mid-tones: smooth inverted transition
    half inverted = 1.0h - lum;
    return half4(half3(inverted), color.a);
}

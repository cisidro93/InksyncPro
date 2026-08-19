#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

// MARK: - Intelligent Dark Mode PDF Shader
// Converts paper white backgrounds to deep OLED dark surfaces and text to crisp off-white,
// while preserving the true hue, saturation, and chroma of embedded photos, diagrams, and colored charts.

[[ stitchable ]] float4 pdfIntelligentDarkMode(coreimage::sample_t s) {
    float3 rgb = s.rgb;
    
    // Perceptual luminance calculation (ITU-R BT.709 standard)
    float lum = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    
    // Color saturation metric
    float maxC = max(rgb.r, max(rgb.g, rgb.b));
    float minC = min(rgb.r, min(rgb.g, rgb.b));
    float sat = (maxC > 0.001) ? (maxC - minC) / maxC : 0.0;
    
    // 1. If pixel has significant color saturation (figures, charts, illustrations), preserve true colors
    if (sat > 0.25) {
        return s;
    }
    
    // 2. Paper White ($lum > 0.82$) -> Invert to dark gray / OLED dark background (#101016)
    if (lum > 0.80) {
        float t = clamp((lum - 0.80) / 0.20, 0.0, 1.0);
        float targetLum = mix(0.14, 0.06, t);
        return float4(float3(targetLum), s.a);
    }
    
    // 3. Black / Dark Text ($lum < 0.22$) -> Invert to high-contrast off-white (#E5E5F0)
    if (lum < 0.22) {
        float t = clamp(lum / 0.22, 0.0, 1.0);
        float targetLum = mix(0.92, 0.78, t);
        return float4(float3(targetLum), s.a);
    }
    
    // 4. Monochrome mid-tones: smooth inverted transition
    float inverted = 1.0 - lum;
    return float4(float3(inverted), s.a);
}

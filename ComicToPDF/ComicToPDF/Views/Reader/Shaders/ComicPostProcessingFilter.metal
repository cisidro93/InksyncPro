#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

// MARK: - Manga Ink Boost & OLED Pure-Black Shaders

/// Manga Ink Boost Filter:
/// Smoothly boosts faded ink lines while whitening dirty paper textures.
/// Preserves true color spreads if chromatic saturation > 0.20.
[[ stitchable ]] float4 mangaInkBoost(coreimage::sample_t s) {
    float3 rgb = s.rgb;
    
    // Perceptual luminance (BT.709)
    float lum = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    
    // Saturation metric
    float maxC = max(rgb.r, max(rgb.g, rgb.b));
    float minC = min(rgb.r, min(rgb.g, rgb.b));
    float sat = (maxC > 0.001) ? (maxC - minC) / maxC : 0.0;
    
    // If the image is a color page/cover, preserve original colors
    if (sat > 0.20) {
        return s;
    }
    
    // Remap luminance [0.15, 0.85] -> [0.0, 1.0] using smoothstep
    float boostedLum = smoothstep(0.15, 0.82, lum);
    return float4(float3(boostedLum), s.a);
}

/// Vintage Color Enhancer:
/// Enhances vintage comic book color printing (Ben-Day dots / 4-color process).
[[ stitchable ]] float4 vintageColorEnhance(coreimage::sample_t s) {
    float3 rgb = s.rgb;
    
    // Perceptual luminance
    float lum = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    
    // Vibrance boost on midtone chromas
    float3 boosted = mix(float3(lum), rgb, 1.35);
    boosted = clamp(boosted, 0.0, 1.0);
    
    return float4(boosted, s.a);
}

/// OLED Pure-Black Border Shader:
/// Clamps near-black letterbox / pillarbox margins strictly to #000000.
[[ stitchable ]] float4 oledPureBlackMargin(coreimage::sample_t s) {
    float3 rgb = s.rgb;
    float lum = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    
    if (lum < 0.04) {
        return float4(0.0, 0.0, 0.0, s.a);
    }
    return s;
}

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// MARK: - Metal Inking Shaders

struct InkVertexInput {
    float2 position          [[attribute(0)]];
    float2 normal            [[attribute(1)]];
    float  width             [[attribute(2)]];
    float4 color             [[attribute(3)]];
    float  relativeYOffset   [[attribute(4)]];
};

struct InkVertexOutput {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

struct InkUniforms {
    float4x4 projectionMatrix;
    float    globalOffsetY;
};

// MARK: - Vertex Shader
// Dynamically extrudes variable-width quads along normal vectors on the GPU.
// Applies relative block hash translation offsets to support seamless text reflow.

vertex InkVertexOutput inkVertexShader(
    InkVertexInput in [[stage_in]],
    constant InkUniforms &uniforms [[buffer(1)]]
) {
    InkVertexOutput out;
    
    // Extrude vertex along normal by half-width
    float2 extrudedPos = in.position + (in.normal * (in.width * 0.5));
    
    // Apply semantic block Y translation
    extrudedPos.y += in.relativeYOffset + uniforms.globalOffsetY;
    
    out.position = uniforms.projectionMatrix * float4(extrudedPos, 0.0, 1.0);
    out.color = in.color;
    out.uv = in.normal; // Normal vector acts as UV coordinate [-1.0 ... 1.0]
    
    return out;
}

// MARK: - Fragment Shader
// Renders anti-aliased, round-edge smooth ink strokes.

fragment float4 inkFragmentShader(
    InkVertexOutput in [[stage_in]]
) {
    // Distance from centerline for anti-aliasing
    float dist = length(in.uv);
    float alpha = smoothstep(1.0, 0.85, dist);
    
    return float4(in.color.rgb, in.color.a * alpha);
}

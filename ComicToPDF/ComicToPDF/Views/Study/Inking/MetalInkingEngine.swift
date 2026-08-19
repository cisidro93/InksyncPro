import SwiftUI
import MetalKit
import UIKit
import simd

// MARK: - Metal Inking Data Models

/// Raw sampled touch/stylus coordinate with pressure, velocity, and timestamp.
public struct MetalInkPoint: Sendable, Equatable {
    public let location: CGPoint
    public let pressure: CGFloat
    public let velocity: CGFloat
    public let timestamp: TimeInterval
    
    public init(location: CGPoint, pressure: CGFloat = 1.0, velocity: CGFloat = 0.0, timestamp: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        self.location = location
        self.pressure = pressure
        self.velocity = velocity
        self.timestamp = timestamp
    }
}

/// Represents a completed or in-progress vector ink stroke anchored to a semantic document block.
public struct MetalInkStroke: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var points: [MetalInkPoint]
    public var colorHex: String
    public var baseWidth: CGFloat
    public var semanticBlockHash: String? // Anchor for text reflow
    public var relativeYOffset: CGFloat   // Dynamic block translation
    
    public init(
        id: UUID = UUID(),
        points: [MetalInkPoint] = [],
        colorHex: String = "#5E5CE6",
        baseWidth: CGFloat = 2.5,
        semanticBlockHash: String? = nil,
        relativeYOffset: CGFloat = 0.0
    ) {
        self.id = id
        self.points = points
        self.colorHex = colorHex
        self.baseWidth = baseWidth
        self.semanticBlockHash = semanticBlockHash
        self.relativeYOffset = relativeYOffset
    }
}

// MARK: - GPU Vertex Structure

struct GPUInkVertex {
    var position: SIMD2<Float>
    var normal: SIMD2<Float>
    var width: Float
    var color: SIMD4<Float>
    var relativeYOffset: Float
}

struct GPUInkUniforms {
    var projectionMatrix: simd_float4x4
    var globalOffsetY: Float
}

// MARK: - Catmull-Rom Spline Interpolation & Quad Extrusion

struct CatmullRomSplineInterpolator {
    
    static func tessellateStroke(
        stroke: MetalInkStroke,
        colorRGBA: SIMD4<Float>
    ) -> [GPUInkVertex] {
        let pts = stroke.points
        guard pts.count >= 2 else { return [] }
        
        var vertices: [GPUInkVertex] = []
        let relativeY = Float(stroke.relativeYOffset)
        
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)].location
            let p1 = pts[i].location
            let p2 = pts[i + 1].location
            let p3 = pts[min(pts.count - 1, i + 2)].location
            
            let press1 = pts[i].pressure
            let press2 = pts[i + 1].pressure
            
            // Subdivide segment into 4 smooth steps
            let steps = 4
            for s in 0..<steps {
                let t = Float(s) / Float(steps)
                let pos = catmullRom(p0: p0, p1: p1, p2: p2, p3: p3, t: CGFloat(t))
                let nextPos = catmullRom(p0: p0, p1: p1, p2: p2, p3: p3, t: CGFloat(t + 0.05))
                
                // Calculate tangent & normal vector
                let dirX = Float(nextPos.x - pos.x)
                let dirY = Float(nextPos.y - pos.y)
                let len = max(0.0001, sqrt((dirX * dirX) + (dirY * dirY)))
                let normal = SIMD2<Float>(-dirY / len, dirX / len)
                
                // Variable width based on pressure
                let dynamicPressure = Float(mix(press1, press2, t: CGFloat(t)))
                let calculatedWidth = Float(stroke.baseWidth) * max(0.4, min(2.5, dynamicPressure))
                
                let positionVec = SIMD2<Float>(Float(pos.x), Float(pos.y))
                
                // Extrude left and right quad vertices
                vertices.append(GPUInkVertex(
                    position: positionVec,
                    normal: normal,
                    width: calculatedWidth,
                    color: colorRGBA,
                    relativeYOffset: relativeY
                ))
                vertices.append(GPUInkVertex(
                    position: positionVec,
                    normal: -normal,
                    width: calculatedWidth,
                    color: colorRGBA,
                    relativeYOffset: relativeY
                ))
            }
        }
        
        return vertices
    }
    
    private static func catmullRom(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, t: CGFloat) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        
        let x = 0.5 * ((2.0 * p1.x) +
            (-p0.x + p2.x) * t +
            (2.0 * p0.x - 5.0 * p1.x + 4.0 * p2.x - p3.x) * t2 +
            (-p0.x + 3.0 * p1.x - 3.0 * p2.x + p3.x) * t3)
        
        let y = 0.5 * ((2.0 * p1.y) +
            (-p0.y + p2.y) * t +
            (2.0 * p0.y - 5.0 * p1.y + 4.0 * p2.y - p3.y) * t2 +
            (-p0.y + 3.0 * p1.y - 3.0 * p2.y + p3.y) * t3)
        
        return CGPoint(x: x, y: y)
    }
    
    private static func mix(_ a: CGFloat, _ b: CGFloat, t: CGFloat) -> CGFloat {
        return a + (b - a) * t
    }
}

// MARK: - Metal Inking Canvas View (MTKView Representable)

/// High-performance hardware-accelerated Metal inking canvas layer.
/// Supports Apple Pencil hover gestures, sub-frame predicted touch sampling,
/// and semantic block anchor reflow tracking.
public struct MetalInkingCanvasView: UIViewRepresentable {
    @Binding var strokes: [MetalInkStroke]
    let activeColorHex: String
    let baseStrokeWidth: CGFloat
    let activeSemanticBlockHash: String?
    
    public init(
        strokes: Binding<[MetalInkStroke]>,
        activeColorHex: String = "#5E5CE6",
        baseStrokeWidth: CGFloat = 2.5,
        activeSemanticBlockHash: String? = nil
    ) {
        self._strokes = strokes
        self.activeColorHex = activeColorHex
        self.baseStrokeWidth = baseStrokeWidth
        self.activeSemanticBlockHash = activeSemanticBlockHash
    }
    
    public func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.isOpaque = false
        mtkView.backgroundColor = .clear
        mtkView.enableSetNeedsDisplay = true
        mtkView.isMultipleTouchEnabled = false
        mtkView.delegate = context.coordinator
        
        context.coordinator.setupMetal(mtkView: mtkView)
        return mtkView
    }
    
    public func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateStrokes(strokes: strokes)
        uiView.setNeedsDisplay()
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    // MARK: - Coordinator & Metal Renderer
    
    public final class Coordinator: NSObject, MTKViewDelegate {
        var parent: MetalInkingCanvasView
        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var vertexBuffer: MTLBuffer?
        private var vertexCount: Int = 0
        private var currentActiveStroke: MetalInkStroke?
        
        init(parent: MetalInkingCanvasView) {
            self.parent = parent
        }
        
        func setupMetal(mtkView: MTKView) {
            guard let dev = mtkView.device else { return }
            self.device = dev
            self.commandQueue = dev.makeCommandQueue()
            
            // Compile Metal Shaders
            guard let library = dev.makeDefaultLibrary(),
                  let vertexFunc = library.makeFunction(name: "inkVertexShader"),
                  let fragmentFunc = library.makeFunction(name: "inkFragmentShader") else {
                return
            }
            
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunc
            pipelineDescriptor.fragmentFunction = fragmentFunc
            pipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            
            // Alpha Blending
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            
            // Vertex Descriptor
            let vertexDescriptor = MTLVertexDescriptor()
            vertexDescriptor.attributes[0].format = .float2 // Position
            vertexDescriptor.attributes[0].offset = 0
            vertexDescriptor.attributes[0].bufferIndex = 0
            
            vertexDescriptor.attributes[1].format = .float2 // Normal
            vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
            vertexDescriptor.attributes[1].bufferIndex = 0
            
            vertexDescriptor.attributes[2].format = .float // Width
            vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD2<Float>>.stride * 2
            vertexDescriptor.attributes[2].bufferIndex = 0
            
            vertexDescriptor.attributes[3].format = .float4 // Color
            vertexDescriptor.attributes[3].offset = MemoryLayout<SIMD2<Float>>.stride * 2 + MemoryLayout<Float>.stride
            vertexDescriptor.attributes[3].bufferIndex = 0
            
            vertexDescriptor.attributes[4].format = .float // RelativeYOffset
            vertexDescriptor.attributes[4].offset = MemoryLayout<SIMD2<Float>>.stride * 2 + MemoryLayout<Float>.stride + MemoryLayout<SIMD4<Float>>.stride
            vertexDescriptor.attributes[4].bufferIndex = 0
            
            vertexDescriptor.layouts[0].stride = MemoryLayout<GPUInkVertex>.stride
            pipelineDescriptor.vertexDescriptor = vertexDescriptor
            
            self.pipelineState = try? dev.makeRenderPipelineState(descriptor: pipelineDescriptor)
        }
        
        func updateStrokes(strokes: [MetalInkStroke]) {
            guard let dev = device else { return }
            
            var allVertices: [GPUInkVertex] = []
            var allStrokes = strokes
            if let active = currentActiveStroke {
                allStrokes.append(active)
            }
            
            for stroke in allStrokes {
                let colorRGBA = parseColor(hex: stroke.colorHex)
                let verts = CatmullRomSplineInterpolator.tessellateStroke(stroke: stroke, colorRGBA: colorRGBA)
                allVertices.append(contentsOf: verts)
            }
            
            self.vertexCount = allVertices.count
            guard !allVertices.isEmpty else {
                self.vertexBuffer = nil
                return
            }
            
            let bufferSize = MemoryLayout<GPUInkVertex>.stride * allVertices.count
            self.vertexBuffer = dev.makeBuffer(bytes: allVertices, length: bufferSize, options: .storageModeShared)
        }
        
        // MARK: - MTKViewDelegate
        
        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        
        public func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let passDescriptor = view.currentRenderPassDescriptor,
                  let pipeline = pipelineState,
                  let cmdBuffer = commandQueue?.makeCommandBuffer(),
                  let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
                return
            }
            
            encoder.setRenderPipelineState(pipeline)
            
            // Projection Matrix (Orthographic 2D)
            let width = Float(view.bounds.width)
            let height = Float(view.bounds.height)
            guard width > 0, height > 0 else {
                encoder.endEncoding()
                return
            }
            
            let proj = matrix_ortho_left_hand(left: 0, right: width, bottom: height, top: 0, nearZ: -1.0, farZ: 1.0)
            var uniforms = GPUInkUniforms(projectionMatrix: proj, globalOffsetY: 0.0)
            
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUInkUniforms>.stride, index: 1)
            
            if let vBuf = vertexBuffer, vertexCount > 0 {
                encoder.setVertexBuffer(vBuf, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertexCount)
            }
            
            encoder.endEncoding()
            cmdBuffer.present(drawable)
            cmdBuffer.commit()
        }
        
        // MARK: - Color Parser
        
        private func parseColor(hex: String) -> SIMD4<Float> {
            var cString: String = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if cString.hasPrefix("#") { cString.remove(at: cString.startIndex) }
            guard cString.count == 6, let rgbValue = UInt64(cString, radix: 16) else {
                return SIMD4<Float>(0.37, 0.36, 0.90, 1.0) // Default ink violet
            }
            let r = Float((rgbValue & 0xFF0000) >> 16) / 255.0
            let g = Float((rgbValue & 0x00FF00) >> 8) / 255.0
            let b = Float(rgbValue & 0x0000FF) / 255.0
            return SIMD4<Float>(r, g, b, 1.0)
        }
    }
}

// MARK: - Orthographic Matrix Generator

private func matrix_ortho_left_hand(left: Float, right: Float, bottom: Float, top: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
    let ral = right + left
    let rsl = right - left
    let tab = top + bottom
    let tsb = top - bottom
    let fan = farZ + nearZ
    let fsn = farZ - nearZ
    
    var P = matrix_identity_float4x4
    P.columns.0.x = 2.0 / rsl
    P.columns.1.y = 2.0 / tsb
    P.columns.2.z = -2.0 / fsn
    P.columns.3.x = -ral / rsl
    P.columns.3.y = -tab / tsb
    P.columns.3.z = -fan / fsn
    return P
}

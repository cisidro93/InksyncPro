import SwiftUI
import MetalKit
import CoreImage

/// A SwiftUI wrapper for an MTKView heavily optimized for Comic Page Rendering
struct MetalCanvasView: UIViewRepresentable {
    var image: CGImage?
    var lockedRect: NormalizedRect
    var isPPLEnabled: Bool
    
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        
        // ✅ Direct Hardware Pipeline Initialization
        if let device = MTLCreateSystemDefaultDevice() {
            mtkView.device = device
            context.coordinator.commandQueue = device.makeCommandQueue()
            
            // We specify a working color space to handle DCI-P3 comic colors gracefully
            let options: [CIContextOption: Any] = [
                .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
                .useSoftwareRenderer: false
            ]
            context.coordinator.ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            print("CRITICAL ENGINE ERROR: Metal is not supported on this device.")
        }
        
        mtkView.framebufferOnly = false
        mtkView.delegate = context.coordinator
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true // We drive the loop manually only on page change
        mtkView.autoResizeDrawable = true
        mtkView.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0)
        
        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.image = image
        context.coordinator.lockedRect = lockedRect
        context.coordinator.isPPLEnabled = isPPLEnabled
        
        // Push the frame through the pipe
        uiView.setNeedsDisplay()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MTKViewDelegate {
        var parent: MetalCanvasView
        var commandQueue: MTLCommandQueue?
        var ciContext: CIContext?
        
        var image: CGImage?
        var lockedRect: NormalizedRect = .full
        var isPPLEnabled: Bool = false
        
        // Double buffering offscreen textures & state cache
        private var frontTexture: MTLTexture?
        private var backTexture: MTLTexture?
        private var lastRenderedImage: CGImage?
        private var lastRenderedLockedRect: NormalizedRect?
        private var lastRenderedPPLEnabled: Bool?
        private var lastRenderedSize: CGSize = .zero
        
        init(_ parent: MetalCanvasView) {
            self.parent = parent
        }
        
        // Auto-sizing trigger hook
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay()
        }
        
        // ✅ The Ultra-Low Latency Double-Buffered Draw Pipe
        func draw(in view: MTKView) {
            guard let device = view.device,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let ciContext = ciContext else {
                return
            }
            
            let drawableSize = view.drawableSize
            // ROTATION SAFETY: MTKView drawable can be .zero during orientation transitions.
            guard drawableSize.width > 1, drawableSize.height > 1 else { return }
            
            // Recreate offscreen textures if size changed or if they don't exist yet
            if drawableSize != lastRenderedSize || frontTexture == nil || backTexture == nil {
                frontTexture = createOffscreenTexture(device: device, size: drawableSize, format: view.colorPixelFormat)
                backTexture = createOffscreenTexture(device: device, size: drawableSize, format: view.colorPixelFormat)
                lastRenderedSize = drawableSize
            }
            
            guard let cgImage = image else {
                // If nil image, just clear the screen using a render pass
                if let renderPassDescriptor = view.currentRenderPassDescriptor {
                    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.05, 1.0)
                    if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                        encoder.endEncoding()
                    }
                    commandBuffer.present(drawable)
                    commandBuffer.commit()
                }
                lastRenderedImage = nil
                lastRenderedLockedRect = nil
                lastRenderedPPLEnabled = nil
                return
            }
            
            let contentChanged = cgImage !== lastRenderedImage || lockedRect != lastRenderedLockedRect || isPPLEnabled != lastRenderedPPLEnabled
            
            if contentChanged || frontTexture == nil {
                // Render the new frame to the backTexture offscreen using Core Image
                guard let targetTexture = backTexture ?? frontTexture else { return }
                
                var ciImage = CIImage(cgImage: cgImage)
                
                // PPL (Page Position Lock) Math Layer
                if isPPLEnabled {
                    let imgWidth = ciImage.extent.width
                    let imgHeight = ciImage.extent.height

                    let cropX = (lockedRect.origin.x / 1000.0) * imgWidth
                    let cropH = (lockedRect.size.height / 1000.0) * imgHeight
                    let cropY = imgHeight - ((lockedRect.origin.y / 1000.0) * imgHeight) - cropH
                    let cropW = (lockedRect.size.width / 1000.0) * imgWidth

                    let cgCropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
                    ciImage = ciImage.cropped(to: cgCropRect)
                    ciImage = ciImage.transformed(by: CGAffineTransform(translationX: -cgCropRect.origin.x, y: -cgCropRect.origin.y))
                }
                
                // Phase 1: Smart Upscaling & Auto Contrast Layer
                let contrastLevel = UserDefaults.standard.double(forKey: "comic_autoContrastLevel")
                if contrastLevel > 1.0 {
                    if let filter = CIFilter(name: "CIColorControls") {
                        filter.setValue(ciImage, forKey: kCIInputImageKey)
                        filter.setValue(contrastLevel, forKey: kCIInputContrastKey)
                        if let output = filter.outputImage { ciImage = output }
                    }
                }
                
                let useSharpening = UserDefaults.standard.bool(forKey: "comic_smartSharpen")
                if useSharpening {
                    if let filter = CIFilter(name: "CISharpenLuminance") {
                        filter.setValue(ciImage, forKey: kCIInputImageKey)
                        filter.setValue(0.7, forKey: kCIInputSharpnessKey)
                        if let output = filter.outputImage { ciImage = output }
                    }
                }

                let imageSize = ciImage.extent.size
                guard imageSize.width > 0, imageSize.height > 0,
                      imageSize.width.isFinite, imageSize.height.isFinite else { return }

                let scaleX = drawableSize.width / imageSize.width
                let scaleY = drawableSize.height / imageSize.height
                let scale = min(scaleX, scaleY)

                let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let xOffset = (drawableSize.width - scaledImage.extent.width) / 2.0
                let yOffset = (drawableSize.height - scaledImage.extent.height) / 2.0
                let centeredImage = scaledImage.transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))

                let destination = CIRenderDestination(width: Int(drawableSize.width),
                                                      height: Int(drawableSize.height),
                                                      pixelFormat: view.colorPixelFormat,
                                                      commandBuffer: commandBuffer,
                                                      mtlTextureProvider: { () -> MTLTexture in
                    return targetTexture
                })

                // Clear targetTexture first
                let offscreenPassDesc = MTLRenderPassDescriptor()
                offscreenPassDesc.colorAttachments[0].texture = targetTexture
                offscreenPassDesc.colorAttachments[0].loadAction = .clear
                offscreenPassDesc.colorAttachments[0].storeAction = .store
                offscreenPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0)
                if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: offscreenPassDesc) {
                    encoder.endEncoding()
                }

                do {
                    _ = try ciContext.startTask(toRender: centeredImage, from: CGRect(origin: .zero, size: drawableSize), to: destination, at: CGPoint.zero)
                } catch {
                    Logger.shared.log("Metal Engine Layout Error: \(error.localizedDescription)", category: "Engine", type: .error)
                }
                
                // Swap textures
                if backTexture != nil {
                    let temp = frontTexture
                    frontTexture = backTexture
                    backTexture = temp
                }
                
                lastRenderedImage = cgImage
                lastRenderedLockedRect = lockedRect
                lastRenderedPPLEnabled = isPPLEnabled
            }
            
            // Blit frontTexture to MTKView drawable texture
            if let sourceTexture = frontTexture {
                if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                    let copyWidth = min(sourceTexture.width, drawable.texture.width)
                    let copyHeight = min(sourceTexture.height, drawable.texture.height)
                    guard copyWidth > 0, copyHeight > 0 else {
                        blitEncoder.endEncoding()
                        return
                    }
                    
                    blitEncoder.copy(from: sourceTexture,
                                     sourceSlice: 0,
                                     sourceLevel: 0,
                                     sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                                     sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                                     to: drawable.texture,
                                     destinationSlice: 0,
                                     destinationLevel: 0,
                                     destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blitEncoder.endEncoding()
                }
            }
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
        
        private func createOffscreenTexture(device: MTLDevice, size: CGSize, format: MTLPixelFormat) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format,
                width: Int(size.width),
                height: Int(size.height),
                mipmapped: false
            )
            desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
            desc.storageMode = .shared
            return device.makeTexture(descriptor: desc)
        }
    }
}

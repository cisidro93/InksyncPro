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
        
        init(_ parent: MetalCanvasView) {
            self.parent = parent
        }
        
        // Auto-sizing trigger hook
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay()
        }
        
        // ✅ The Ultra-Low Latency Draw Pipe
        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let cgImage = image,
                  let ciContext = ciContext else {
                
        // If nil image, just clear the screen
                if let commandBuffer = commandQueue?.makeCommandBuffer(),
                   let drawable = view.currentDrawable,
                   let renderPassDescriptor = view.currentRenderPassDescriptor {
                    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.05, 1.0)
                    if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                        encoder.endEncoding()
                    }
                    commandBuffer.present(drawable)
                    commandBuffer.commit()
                }
                return
            }
            
            var ciImage = CIImage(cgImage: cgImage)
            let drawableSize = view.drawableSize

            // ROTATION SAFETY: MTKView drawable can be .zero during orientation transitions.
            // Creating a CIRenderDestination with zero dimensions crashes Core Image.
            guard drawableSize.width > 1, drawableSize.height > 1 else { return }

            // PPL (Page Position Lock) Math Layer
            if isPPLEnabled {
                // Denormalize the coordinate lock into raw pixel offsets
                let imgWidth = ciImage.extent.width
                let imgHeight = ciImage.extent.height

                let cropX = (lockedRect.origin.x / 1000.0) * imgWidth
                // CoreImage origin is bottom-left, we must invert Y
                let cropH = (lockedRect.size.height / 1000.0) * imgHeight
                let cropY = imgHeight - ((lockedRect.origin.y / 1000.0) * imgHeight) - cropH
                let cropW = (lockedRect.size.width / 1000.0) * imgWidth

                let cgCropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
                ciImage = ciImage.cropped(to: cgCropRect)

                // Shift the origin back down to 0,0 avoiding blank offset gaps
                ciImage = ciImage.transformed(by: CGAffineTransform(translationX: -cgCropRect.origin.x, y: -cgCropRect.origin.y))
            }
            
            // ✅ Phase 1: Smart Upscaling & Auto Contrast Layer
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
                    filter.setValue(0.7, forKey: kCIInputSharpnessKey) // A balanced sharp threshold
                    if let output = filter.outputImage { ciImage = output }
                }
            }

            let imageSize = ciImage.extent.size
            // SAFETY: Guard against zero or infinite image extent (e.g., corrupt PPL crop result)
            guard imageSize.width > 0, imageSize.height > 0,
                  imageSize.width.isFinite, imageSize.height.isFinite else { return }

            let scaleX = drawableSize.width / imageSize.width
            let scaleY = drawableSize.height / imageSize.height
            // Fit to screen perfectly
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
                return drawable.texture
            })

            do {
                _ = try ciContext.startTask(toRender: centeredImage, from: CGRect(origin: .zero, size: drawableSize), to: destination, at: CGPoint.zero)
            } catch {
                Logger.shared.log("Metal Engine Layout Error: \(error.localizedDescription)", category: "Engine", type: .error)
            }
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

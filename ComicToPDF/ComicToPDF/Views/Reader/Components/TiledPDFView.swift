//
//  TiledPDFView.swift
//  InksyncPro
//
//  CATiledLayer Memory Shield for High-Resolution PDF & Manga Rendering.
//  Renders 512x512 tile chunks asynchronously on background threads to
//  eliminate Out-Of-Memory (OOM) crashes on 4K/8K manga scans while maintaining 120Hz ProMotion performance.
//

import UIKit
import PDFKit
import CoreGraphics
import QuartzCore

// MARK: - TiledPDFView
@MainActor
final class TiledPDFView: UIView {
    
    // Core PDF page reference
    var pdfPage: CGPDFPage? {
        didSet {
            setNeedsDisplay()
        }
    }
    
    // Scale factor matching outer zoom level
    var pageScale: CGFloat = 1.0 {
        didSet {
            if abs(oldValue - pageScale) > 0.01 {
                setNeedsDisplay()
            }
        }
    }
    
    // Display box mode (.cropBox vs .mediaBox)
    var displayBox: PDFDisplayBox = .mediaBox {
        didSet {
            setNeedsDisplay()
        }
    }
    
    // Configure CATiledLayer as the backing layer
    override class var layerClass: AnyClass {
        return CATiledLayer.self
    }
    
    private var tiledLayer: CATiledLayer {
        return layer as! CATiledLayer
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupTiledLayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTiledLayer()
    }
    
    private func setupTiledLayer() {
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        
        // 512x512 tile size balances memory efficiency and GPU draw-call throughput
        tiledLayer.tileSize = CGSize(width: 512, height: 512)
        tiledLayer.levelsOfDetail = 4
        tiledLayer.levelsOfDetailBias = 3
    }
    
    override func draw(_ rect: CGRect) {
        guard let page = pdfPage, let context = UIGraphicsGetCurrentContext() else { return }
        
        // Save graphics context state
        context.saveGState()
        
        // Get target box bounds
        let boxRect: CGRect
        switch displayBox {
        case .cropBox:
            boxRect = page.getBoxRect(.cropBox)
        default:
            boxRect = page.getBoxRect(.mediaBox)
        }
        
        guard boxRect.width > 0 && boxRect.height > 0 else {
            context.restoreGState()
            return
        }
        
        // Downsampling Memory Guard: Clamp render scale to 3x native screen scale
        let maxScale = UIScreen.main.scale * 3.0
        let currentScaleX = abs(context.ctm.a)
        let currentScaleY = abs(context.ctm.d)
        if currentScaleX > maxScale || currentScaleY > maxScale {
            let scaleClampX = maxScale / max(currentScaleX, 0.001)
            let scaleClampY = maxScale / max(currentScaleY, 0.001)
            context.scaleBy(x: scaleClampX, y: scaleClampY)
        }
        
        // Setup Quartz coordinates (Flip Y for CoreGraphics PDF coordinate space)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1.0, y: -1.0)
        
        // Scale to fit target view bounds
        let scaleX = bounds.width / boxRect.width
        let scaleY = bounds.height / boxRect.height
        context.scaleBy(x: scaleX, y: scaleY)
        context.translateBy(x: -boxRect.origin.x, y: -boxRect.origin.y)
        
        // High quality interpolation for fine text/manga linework
        context.interpolationQuality = .high
        context.setRenderingIntent(.defaultIntent)
        
        // Draw PDF page asynchronously via CATiledLayer background thread invocation
        context.drawPDFPage(page)
        
        context.restoreGState()
    }
}

// MARK: - TiledPDFViewRepresentable (SwiftUI Wrapper)
struct TiledPDFViewRepresentable: UIViewRepresentable {
    let pdfPage: PDFPage?
    let displayBox: PDFDisplayBox
    let scale: CGFloat
    
    func makeUIView(context: Context) -> TiledPDFView {
        let view = TiledPDFView(frame: .zero)
        view.pdfPage = pdfPage?.pageRef
        view.displayBox = displayBox
        view.pageScale = scale
        return view
    }
    
    func updateUIView(_ uiView: TiledPDFView, context: Context) {
        if uiView.pdfPage != pdfPage?.pageRef {
            uiView.pdfPage = pdfPage?.pageRef
        }
        if uiView.displayBox != displayBox {
            uiView.displayBox = displayBox
        }
        if abs(uiView.pageScale - scale) > 0.01 {
            uiView.pageScale = scale
        }
    }
}

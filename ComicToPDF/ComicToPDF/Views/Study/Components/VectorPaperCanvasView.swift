import SwiftUI

// MARK: - Goodnotes-Style Vector Paper Canvas View

/// High-performance SwiftUI Canvas rendering mathematical paper templates with zero pixelation.
public struct VectorPaperCanvasView: View {
    let template: VectorPaperTemplate
    var spacing: CGFloat = 26.0
    
    @Environment(\.colorScheme) private var colorScheme
    
    private let renderer = PaperTemplateRenderer.shared
    
    public init(template: VectorPaperTemplate, spacing: CGFloat = 26.0) {
        self.template = template
        self.spacing = spacing
    }
    
    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            
            ZStack {
                // Paper Base Tint
                Color.inkBackground
                    .ignoresSafeArea()
                
                switch template {
                case .cornellClassic:
                    cornellView(size: size)
                    
                case .dotGrid:
                    dotGridView(size: size)
                    
                case .engineeringGrid:
                    engineeringGridView(size: size)
                    
                case .isometricGrid:
                    isometricGridView(size: size)
                    
                case .linedCollegeRuled:
                    collegeRuledView(size: size)
                    
                case .hexagonalGrid:
                    hexagonalGridView(size: size)
                    
                case .blankCanvas:
                    EmptyView()
                }
            }
        }
        .allowsHitTesting(false) // Non-blocking background
    }
    
    // MARK: - Template Renderers
    
    @ViewBuilder
    private func cornellView(size: CGSize) -> some View {
        let metrics = PaperTemplateRenderer.CornellMetrics(
            cueColumnWidth: min(140.0, size.width * 0.32),
            summarySectionHeight: 130.0,
            headerHeight: 50.0,
            lineSpacing: spacing
        )
        
        let dividerPath = renderer.createCornellDividersPath(in: size, metrics: metrics)
        let ruledLinesPath = renderer.createRuledLinesPath(
            in: size,
            startY: metrics.headerHeight,
            endY: size.height - metrics.summarySectionHeight,
            spacing: metrics.lineSpacing
        )
        
        ZStack(alignment: .topLeading) {
            // Horizontal Ruled Lines (Subtle)
            ruledLinesPath
                .stroke(
                    Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.07),
                    lineWidth: 0.5
                )
            
            // Major Dividers (Prominent)
            dividerPath
                .stroke(
                    Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.20),
                    lineWidth: 1.0
                )
            
            // Watermark Zone Labels
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("CUES / RECALL")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.inkTextTertiary.opacity(0.6))
                        .padding(.leading, 8)
                        .padding(.top, 18)
                    
                    Spacer()
                    
                    Text("NOTES / SYNTAX")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.inkTextTertiary.opacity(0.6))
                        .padding(.trailing, 16)
                        .padding(.top, 18)
                }
                
                Spacer()
                
                Text("SUMMARY & SYNTHESIS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.inkTextTertiary.opacity(0.6))
                    .padding(.leading, 12)
                    .padding(.bottom, 114)
            }
        }
    }
    
    @ViewBuilder
    private func dotGridView(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let dotSpacing: CGFloat = 20.0
            let dotRadius: CGFloat = 1.0
            let dotColor = (colorScheme == .dark)
                ? Color.white.opacity(0.18)
                : Color.black.opacity(0.15)
            
            var x: CGFloat = dotSpacing
            while x < canvasSize.width {
                var y: CGFloat = dotSpacing
                while y < canvasSize.height {
                    let dotRect = CGRect(
                        x: x - dotRadius,
                        y: y - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    )
                    context.fill(Path(ellipseIn: dotRect), with: .color(dotColor))
                    y += dotSpacing
                }
                x += dotSpacing
            }
        }
    }
    
    @ViewBuilder
    private func engineeringGridView(size: CGSize) -> some View {
        let (minor, major) = renderer.createEngineeringGridPaths(in: size, minorSpacing: 6.0, majorInterval: 5)
        
        ZStack {
            minor.stroke(
                Color.inkGreen.opacity(colorScheme == .dark ? 0.08 : 0.09),
                lineWidth: 0.3
            )
            major.stroke(
                Color.inkGreen.opacity(colorScheme == .dark ? 0.25 : 0.22),
                lineWidth: 0.8
            )
        }
    }
    
    @ViewBuilder
    private func isometricGridView(size: CGSize) -> some View {
        let isoPath = renderer.createIsometricGridPath(in: size, spacing: 24.0)
        isoPath.stroke(
            Color.inkBlue.opacity(colorScheme == .dark ? 0.12 : 0.10),
            lineWidth: 0.5
        )
    }
    
    @ViewBuilder
    private func collegeRuledView(size: CGSize) -> some View {
        let ruledPath = renderer.createRuledLinesPath(in: size, startY: 30.0, endY: nil, spacing: 22.0)
        let leftMarginX: CGFloat = 48.0
        
        ZStack(alignment: .leading) {
            // Horizontal Ruled Lines
            ruledPath.stroke(
                Color.inkBlue.opacity(colorScheme == .dark ? 0.14 : 0.12),
                lineWidth: 0.5
            )
            
            // Vertical Left Margin Rule (Red / Rose)
            Path { path in
                path.move(to: CGPoint(x: leftMarginX, y: 0))
                path.addLine(to: CGPoint(x: leftMarginX, y: size.height))
            }
            .stroke(
                Color.inkRed.opacity(colorScheme == .dark ? 0.35 : 0.30),
                lineWidth: 1.0
            )
        }
    }
    
    @ViewBuilder
    private func hexagonalGridView(size: CGSize) -> some View {
        let hexPath = renderer.createHexagonalGridPath(in: size, radius: 18.0)
        hexPath.stroke(
            Color.inkAmber.opacity(colorScheme == .dark ? 0.12 : 0.10),
            lineWidth: 0.5
        )
    }
}

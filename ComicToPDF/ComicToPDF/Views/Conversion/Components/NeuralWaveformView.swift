import SwiftUI

/// A high-performance, metal-rendered animated neural waveform component.
/// Uses `TimelineView` and `Canvas` to draw multiple overlapping sine waves
/// representing background processing/thinking states, exactly like Gemini.
struct NeuralWaveformView: View {
    let speed: Double
    let primaryColor: Color
    let secondaryColor: Color

    init(
        speed: Double = 1.8,
        primaryColor: Color = .inkBlue,
        secondaryColor: Color = .inkViolet
    ) {
        self.speed = speed
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
    }

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate * speed
            
            Canvas { gc, size in
                let midY = size.height / 2
                let width = size.width
                
                // Draw 3 overlapping sine waves with differing amplitudes and phases
                drawWave(
                    in: &gc,
                    size: size,
                    midY: midY,
                    width: width,
                    time: time,
                    color: primaryColor,
                    opacity: 0.6,
                    frequency: 0.025,
                    amplitude: size.height * 0.35,
                    phaseShift: 0.0
                )
                
                drawWave(
                    in: &gc,
                    size: size,
                    midY: midY,
                    width: width,
                    time: time,
                    color: secondaryColor,
                    opacity: 0.55,
                    frequency: 0.035,
                    amplitude: size.height * 0.28,
                    phaseShift: Double.pi * 0.5
                )
                
                drawWave(
                    in: &gc,
                    size: size,
                    midY: midY,
                    width: width,
                    time: time,
                    color: Color(hex: "#00d2ff"),
                    opacity: 0.45,
                    frequency: 0.018,
                    amplitude: size.height * 0.22,
                    phaseShift: Double.pi * 1.2
                )
            }
        }
        .frame(height: 48)
    }

    private func drawWave(
        in gc: inout GraphicsContext,
        size: CGSize,
        midY: CGFloat,
        width: CGFloat,
        time: Double,
        color: Color,
        opacity: Double,
        frequency: CGFloat,
        amplitude: CGFloat,
        phaseShift: Double
    ) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: midY))
        
        let resolution: CGFloat = 2.0
        for x in stride(from: 0, to: width, by: resolution) {
            // Apply a sine wave function modulated by time, x-coordinate, and a starting phase
            let phase = CGFloat(time) + phaseShift
            // We use a cosine envelope to damp the wave at the leading and trailing edges (fade out at ends)
            let relativeX = x / width
            let envelope = sin(relativeX * CGFloat.pi) // damp both ends to 0
            
            let y = midY + sin(x * frequency + phase) * amplitude * envelope
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
        gc.opacity = opacity
        gc.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
        )
    }
}

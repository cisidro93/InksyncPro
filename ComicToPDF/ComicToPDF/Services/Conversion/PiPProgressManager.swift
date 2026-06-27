import Foundation
import UIKit
import AVFoundation
import AVKit
import SwiftUI
import Combine
import CoreMedia
import CoreVideo

@MainActor
final class PiPProgressManager: NSObject, ObservableObject {
    static let shared = PiPProgressManager()
    
    private var pipController: AVPictureInPictureController?
    private var sampleBufferLayer: AVSampleBufferDisplayLayer?
    private var cancellables = Set<AnyCancellable>()
    
    @Published var isPiPActive = false
    
    private override init() {
        super.init()
    }
    
    func setupPiP(with window: UIWindow?) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        
        let sampleLayer = AVSampleBufferDisplayLayer()
        sampleLayer.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        sampleLayer.videoGravity = .resizeAspect
        self.sampleBufferLayer = sampleLayer
        
        // Add sample layer offscreen in the window hierarchy so Picture-in-Picture can bind to it
        let containerView = UIView(frame: CGRect(x: -1000, y: -1000, width: 320, height: 180))
        containerView.layer.addSublayer(sampleLayer)
        window?.addSubview(containerView)
        
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleLayer,
            playbackDelegate: self
        )
        
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        self.pipController = controller
    }
    
    func observeConversion() {
        TaskEngine.shared.$isConverting
            .combineLatest(TaskEngine.shared.$conversionProgress, TaskEngine.shared.$processingStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConverting, progress, status in
                guard let self = self else { return }
                let title = status.isEmpty ? "Converting..." : status
                if isConverting {
                    if !self.isPiPActive {
                        self.startPiP(title: title, initialProgress: progress)
                    } else {
                        self.updateProgressFrame(title: title, progress: progress)
                    }
                } else {
                    if self.isPiPActive {
                        self.stopPiP()
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    func startPiP(title: String, initialProgress: Double) {
        guard let controller = pipController, !controller.isPictureInPictureActive else { return }
        
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("PiPProgressManager: Failed to configure audio session: \(error)")
        }
        
        updateProgressFrame(title: title, progress: initialProgress)
        controller.startPictureInPicture()
    }
    
    func stopPiP() {
        pipController?.stopPictureInPicture()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    
    private func renderView(title: String, progress: Double) -> UIImage? {
        let view = PiPProgressView(title: title, progress: progress)
        let hostingController = UIHostingController(rootView: view)
        hostingController.view.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        hostingController.view.backgroundColor = .black
        
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180))
        return renderer.image { _ in
            hostingController.view.drawHierarchy(in: hostingController.view.bounds, afterScreenUpdates: true)
        }
    }
    
    private func updateProgressFrame(title: String, progress: Double) {
        guard let image = renderView(title: title, progress: progress),
              let cgImage = image.cgImage,
              let layer = sampleBufferLayer else { return }
        
        let width = cgImage.width
        let height = cgImage.height
        
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
        ] as CFDictionary
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return }
        
        CVPixelBufferLockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard let format = formatDescription else { return }
        
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: Int64(CACurrentMediaTime() * 30), timescale: 30),
            decodeTimeStamp: .invalid
        )
        
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        if let sBuffer = sampleBuffer {
            if layer.isReadyForMoreMediaData {
                layer.enqueue(sBuffer)
            }
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate
extension PiPProgressManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
    
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .zero, duration: .indefinite)
    }
    
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false
    }
    
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        completion()
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PiPProgressManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = true
        }
    }
    
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = false
        }
    }
    
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.isPiPActive = false
        }
    }
}

// MARK: - PiP Progress Swift View
struct PiPProgressView: View {
    let title: String
    let progress: Double
    
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up.trianglebadge.exclamationmark")
                    .foregroundColor(.orange)
                    .font(.system(size: 16, weight: .bold))
                
                Text("Kindle Conversion Active")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }
            
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.gray)
                .lineLimit(1)
                .padding(.horizontal, 16)
            
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.15))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.orange)
                            .frame(width: geo.size.width * CGFloat(progress))
                    }
                }
                .frame(height: 8)
                
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, 24)
        }
        .frame(width: 320, height: 180)
        .background(Color(white: 0.05))
    }
}

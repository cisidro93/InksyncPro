import Foundation
import CoreMotion
import UIKit

@MainActor
public final class BackTapManager {
    public static let shared = BackTapManager()
    
    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    
    private var lastSpikeTime: TimeInterval = 0
    private var tapCount = 0
    private var firstTapTime: TimeInterval = 0
    private let threshold: Double = 1.5 // Gs (User acceleration magnitude along Z-axis)
    private let debounceInterval: TimeInterval = 0.20 // 200ms to ignore reverberations
    private let tapWindow: TimeInterval = 0.35 // 350ms window to count taps
    
    public var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
    }
    
    private var isMonitoring = false
    
    private init() {
        queue.name = "com.inksync.backtap"
        queue.maxConcurrentOperationCount = 1
        
        // Auto suspend/resume accelerometer on app lifecycle transitions to preserve battery
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    @objc private func handleBackground() {
        if isEnabled {
            stopMonitoring()
        }
    }
    
    @objc private func handleForeground() {
        if isEnabled {
            startMonitoring()
        }
    }
    
    private func startMonitoring() {
        guard motionManager.isDeviceMotionAvailable else { return }
        guard !isMonitoring else { return }
        
        motionManager.deviceMotionUpdateInterval = 0.01 // 100Hz sampling rate
        let threshold = self.threshold
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let motion = motion, error == nil else { return }
            
            let accelZ = motion.userAcceleration.z
            let magnitude = abs(accelZ)
            
            if magnitude > threshold {
                Task { @MainActor in
                    self?.handlePotentialTap()
                }
            }
        }
        isMonitoring = true
    }
    
    private func stopMonitoring() {
        guard isMonitoring else { return }
        motionManager.stopDeviceMotionUpdates()
        isMonitoring = false
        tapCount = 0
    }
    
    private func handlePotentialTap() {
        let now = Date().timeIntervalSince1970
        if now - lastSpikeTime > debounceInterval {
            lastSpikeTime = now
            registerTap()
        }
    }
    
    private func registerTap() {
        let now = Date().timeIntervalSince1970
        if self.tapCount == 0 {
            self.firstTapTime = now
            self.tapCount = 1
            
            // Close the window and evaluate taps after 350ms
            let window = self.tapWindow
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
                self.evaluateTaps()
            }
        } else {
            self.tapCount += 1
        }
    }
    
    private func evaluateTaps() {
        let finalCount = tapCount
        tapCount = 0
        
        guard isEnabled else { return }
        
        if finalCount == 2 {
            NotificationCenter.default.post(name: NSNotification.Name("Reader_NextPage"), object: nil)
        } else if finalCount >= 3 {
            NotificationCenter.default.post(name: NSNotification.Name("Reader_PrevPage"), object: nil)
        }
    }
}

import Foundation
import UIKit

// ============================================================================
// AmbientBrightnessManager
// ============================================================================
// Automatically recommends warmth levels based on time of day. Requires NO
// location permissions. Uses configurable hour thresholds stored in UserDefaults.
//
// Night mode windows span midnight correctly (e.g. 20:00 → 07:00).
// The manager fires every 60 seconds so warmth transitions happen smoothly
// within one minute of the user-defined threshold without draining the battery.
// ============================================================================

@MainActor
final class AmbientBrightnessManager: ObservableObject {
    static let shared = AmbientBrightnessManager()

    // MARK: - Published
    @Published private(set) var recommendedWarmth: Double = 0.0
    @Published private(set) var isNightMode: Bool = false

    // MARK: - Settings (persisted via UserDefaults)
    // Note: @AppStorage is a View-only property wrapper; use UserDefaults directly in ObservableObject classes.
    var autoNightMode: Bool {
        get { UserDefaults.standard.object(forKey: "reader_autoNightMode") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "reader_autoNightMode") }
    }
    var nightStartHour: Double {
        get { UserDefaults.standard.object(forKey: "reader_nightModeStartHour") as? Double ?? 20.0 }
        set { UserDefaults.standard.set(newValue, forKey: "reader_nightModeStartHour") }
    }
    var nightEndHour: Double {
        get { UserDefaults.standard.object(forKey: "reader_nightModeEndHour") as? Double ?? 7.0 }
        set { UserDefaults.standard.set(newValue, forKey: "reader_nightModeEndHour") }
    }
    var nightWarmth: Double {
        get { UserDefaults.standard.object(forKey: "reader_nightModeWarmth") as? Double ?? 0.22 }
        set { UserDefaults.standard.set(newValue, forKey: "reader_nightModeWarmth") }
    }

    // MARK: - Private
    private var timer: Timer?

    private init() {
        evaluate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
    }

    // MARK: - Public

    /// Force-evaluate immediately (e.g. when user changes settings).
    func evaluate() {
        guard autoNightMode else {
            isNightMode = false
            recommendedWarmth = 0.0
            return
        }

        let cal  = Calendar.current
        let now  = Date()
        let hour = Double(cal.component(.hour,   from: now))
        let min  = Double(cal.component(.minute, from: now)) / 60.0
        let time = hour + min

        let inNight: Bool
        if nightStartHour > nightEndHour {
            // Spans midnight: 20:00 → 07:00
            inNight = time >= nightStartHour || time < nightEndHour
        } else {
            // Doesn't span midnight (unusual config)
            inNight = time >= nightStartHour && time < nightEndHour
        }

        // Smooth transition — SwiftUI will animate published changes via .animation()
        isNightMode       = inNight
        recommendedWarmth = inNight ? nightWarmth : 0.0
    }

    /// Returns a human-readable description of the current night window.
    var nightWindowDescription: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        let start = Calendar.current.date(bySettingHour: Int(nightStartHour), minute: 0, second: 0, of: Date()) ?? Date()
        let end   = Calendar.current.date(bySettingHour: Int(nightEndHour),   minute: 0, second: 0, of: Date()) ?? Date()
        return "\(fmt.string(from: start)) – \(fmt.string(from: end))"
    }
}

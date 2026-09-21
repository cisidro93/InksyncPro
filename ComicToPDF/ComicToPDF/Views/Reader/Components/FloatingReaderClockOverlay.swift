import SwiftUI
import Combine

/// Battery-efficient, floating executive clock & battery header overlay for Reader views.
struct FloatingReaderClockOverlay: View {
    @ObservedObject var prefs: EBookPreferences = .shared
    @State private var currentTimeString: String = ""
    @State private var batteryPercentageString: String = ""
    @State private var timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    
    var body: some View {
        if prefs.showClockHeader {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(currentTimeString)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                
                if prefs.showBatteryPercentage && !batteryPercentageString.isEmpty {
                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Image(systemName: "battery.100")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(batteryPercentageString)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
            .padding(.top, 6)
            .onAppear {
                if prefs.showBatteryPercentage {
                    UIDevice.current.isBatteryMonitoringEnabled = true
                }
                updateTimeAndBattery()
            }
            .onDisappear {
                UIDevice.current.isBatteryMonitoringEnabled = false
            }
            .onReceive(timer) { _ in
                updateTimeAndBattery()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
                updateTimeAndBattery()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                updateTimeAndBattery()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                if prefs.showBatteryPercentage {
                    UIDevice.current.isBatteryMonitoringEnabled = true
                }
                updateTimeAndBattery()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                UIDevice.current.isBatteryMonitoringEnabled = false
            }
        }
    }
    
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
    
    private func updateTimeAndBattery() {
        currentTimeString = Self.timeFormatter.string(from: Date())
        
        let batteryLevel = UIDevice.current.batteryLevel
        if batteryLevel >= 0 {
            batteryPercentageString = "\(Int(batteryLevel * 100))%"
        } else {
            batteryPercentageString = ""
        }
    }
}

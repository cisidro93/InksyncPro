import SwiftUI
import Combine

/// Battery-efficient, floating executive clock & battery header overlay for Reader views.
struct FloatingReaderClockOverlay: View {
    @ObservedObject var prefs: EBookPreferences = .shared
    @State private var currentTimeString: String = ""
    @State private var batteryPercentageString: String = ""
    @State private var timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    
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
                updateTimeAndBattery()
            }
            .onReceive(timer) { _ in
                updateTimeAndBattery()
            }
        }
    }
    
    private func updateTimeAndBattery() {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        currentTimeString = formatter.string(from: Date())
        
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = UIDevice.current.batteryLevel
        if batteryLevel >= 0 {
            batteryPercentageString = "\(Int(batteryLevel * 100))%"
        } else {
            batteryPercentageString = ""
        }
    }
}

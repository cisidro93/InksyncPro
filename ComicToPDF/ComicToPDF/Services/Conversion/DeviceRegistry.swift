import SwiftUI
import Foundation

@MainActor
class DeviceRegistry: ObservableObject {
    static let shared = DeviceRegistry()
    
    // Holds the primary network resolution selection for P2P and export
    @Published var primaryDeviceID: UUID? {
        didSet {
            // Deprecated: No longer saves to ConversionManager library.json. State should be synced via another mechanism or bound in the UI.
        }
    }
    
    // Legacy mapping (to be deprecated in Phase 2)
    @Published var registeredDevices: [RegisteredDevice] = []
    
    var primaryDevice: RegisteredDevice? {
        registeredDevices.first { $0.id == primaryDeviceID } ?? registeredDevices.first
    }
}

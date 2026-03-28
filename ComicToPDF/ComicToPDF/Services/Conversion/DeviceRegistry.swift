import SwiftUI
import Foundation

@MainActor
class DeviceRegistry: ObservableObject {
    static let shared = DeviceRegistry()
    
    // Holds the primary network resolution selection for P2P and export
    @Published var primaryDeviceID: UUID? {
        didSet {
            // Trigger an auto-save when this changes since it was historically bound to ConversionManager's library.json
            Task { await MainActor.run { ConversionManager.sharedIfAvailable?.saveLibrary() } }
        }
    }
    
    // Legacy mapping (to be deprecated in Phase 2)
    @Published var registeredDevices: [RegisteredDevice] = []
    
    var primaryDevice: RegisteredDevice? {
        registeredDevices.first { $0.id == primaryDeviceID } ?? registeredDevices.first
    }
}

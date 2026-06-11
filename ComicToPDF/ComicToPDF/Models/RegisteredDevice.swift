import Foundation

struct RegisteredDevice: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var deviceType: DeviceType
    var transferMethod: TransferMethod
    var kindleEmail: String?
    var isOnline: Bool = false  // runtime only, not persisted

    enum DeviceType: String, Codable, CaseIterable {
        case kindleColorsoft = "Kindle Colorsoft"
        case kindlePaperwhite = "Kindle Paperwhite"
        case kindleScribe = "Kindle Scribe"
        case iPad = "iPad"
        case other = "Other"

        var sfSymbol: String {
            switch self {
            case .kindleColorsoft, .kindlePaperwhite, .kindleScribe: return "e.reader"
            case .iPad: return "ipad"
            case .other: return "desktopcomputer"
            }
        }

        var isKindle: Bool {
            self != .iPad && self != .other
        }
    }

    enum TransferMethod: String, Codable, CaseIterable {
        case airDrop = "AirDrop"
        case webDAV = "WebDAV"
        case sendToKindle = "Send to Kindle"
        case saveToFiles = "Save to Files"
    }
}

import SwiftData

@Model
final class SDRegisteredDevice: Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var rawDeviceType: String
    var rawTransferMethod: String
    var kindleEmail: String?
    
    // Derived properties
    var deviceType: RegisteredDevice.DeviceType {
        get { RegisteredDevice.DeviceType(rawValue: rawDeviceType) ?? .other }
        set { rawDeviceType = newValue.rawValue }
    }
    var transferMethod: RegisteredDevice.TransferMethod {
        get { RegisteredDevice.TransferMethod(rawValue: rawTransferMethod) ?? .airDrop }
        set { rawTransferMethod = newValue.rawValue }
    }
    
    @Transient var isOnline: Bool = false
    
    init(id: UUID = UUID(), name: String, deviceType: RegisteredDevice.DeviceType, transferMethod: RegisteredDevice.TransferMethod, kindleEmail: String? = nil) {
        self.id = id
        self.name = name
        self.rawDeviceType = deviceType.rawValue
        self.rawTransferMethod = transferMethod.rawValue
        self.kindleEmail = kindleEmail
    }

    // SwiftData @Model classes do NOT get synthesized Equatable from the compiler.
    // Providing an explicit == based on `id` ensures identity is judged by the
    // persistent primary key, not by pointer address or memberwise comparison.
    static func == (lhs: SDRegisteredDevice, rhs: SDRegisteredDevice) -> Bool {
        lhs.id == rhs.id
    }
}

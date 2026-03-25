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
        case kfxHandoff = "Kindle via Mac/PC"
        case sendToKindle = "Send to Kindle"
        case saveToFiles = "Save to Files"
    }
}

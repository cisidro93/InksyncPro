import Foundation
import Combine

// Actor-isolated transfer log.
// Maximum 200 events. IP addresses are masked to the first 3 octets (e.g. 192.168.1.xxx).
// Combine publisher notifies observers on new events.

actor WiFiTransferLog {
    static let shared = WiFiTransferLog()

    private let maxEvents = 200
    private var events: [TransferEvent] = []
    private let subject = PassthroughSubject<TransferEvent, Never>()

    nonisolated var publisher: AnyPublisher<TransferEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    struct TransferEvent: Identifiable, Sendable {
        let id: UUID = UUID()
        let date: Date
        let maskedIP: String
        let filename: String
        let sizeBytes: Int64
        let direction: Direction
        let succeeded: Bool

        enum Direction: String, Sendable {
            case upload   = "Upload"
            case download = "Download"
        }
    }

    private init() {}

    func record(
        ip: String,
        filename: String,
        sizeBytes: Int64,
        direction: TransferEvent.Direction,
        succeeded: Bool
    ) {
        let event = TransferEvent(
            date: Date(),
            maskedIP: mask(ip: ip),
            filename: filename,
            sizeBytes: sizeBytes,
            direction: direction,
            succeeded: succeeded
        )
        events.append(event)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
        subject.send(event)
    }

    func recentEvents() -> [TransferEvent] {
        Array(events.suffix(maxEvents))
    }

    func clear() {
        events.removeAll()
    }

    private func mask(ip: String) -> String {
        let parts = ip.components(separatedBy: ".")
        guard parts.count == 4 else { return ip }
        return "\(parts[0]).\(parts[1]).\(parts[2]).xxx"
    }
}

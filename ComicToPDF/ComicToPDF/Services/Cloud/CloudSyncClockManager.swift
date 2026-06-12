import Foundation

// Actor-isolated vector clock manager.
// Swift 6 compliant — no shared mutable state outside the actor.

actor CloudSyncClockManager {
    private var localClock: Int = 0
    private var remoteClock: [String: Int] = [:]

    private let deviceID: String

    init(deviceID: String = DeviceIdentity.shared.deviceID) {
        self.deviceID = deviceID
    }

    // Increment local clock and return new value.
    func tick() -> Int {
        localClock += 1
        return localClock
    }

    // Merge a remote vector into local understanding.
    // Takes max of each known device's clock value.
    func merge(_ remote: [String: Int]) {
        for (device, clock) in remote {
            remoteClock[device] = max(remoteClock[device] ?? 0, clock)
        }
        if let remoteLocalClock = remote[deviceID] {
            localClock = max(localClock, remoteLocalClock)
        }
    }

    // Returns the full vector clock for outgoing sync envelopes.
    func currentVector() -> [String: Int] {
        var vector = remoteClock
        vector[deviceID] = localClock
        return vector
    }
}

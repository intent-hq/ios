import Foundation

extension PersistenceManager {
    /// One attempt per pending backend per pairing/foreground opportunity.
    /// Backfill uses the original pairing time, never today's clock, so an
    /// old installation cannot revive a newer shared removal or edit.
    func publishPendingBackends() {
        guard let backendPublisher, var connections = loadConnectionsWithOutcome().connections else { return }
        var queuedBackfill = false
        for index in connections.indices where connections[index].syncUpdatedAt == nil
            && connections[index].pendingSyncUpdatedAt == nil {
            connections[index].pendingSyncUpdatedAt = connections[index].server.pairedAt.timeIntervalSince1970 * 1000 // swiftlint:disable:this no_magic_numbers
            queuedBackfill = true
        }
        // No shared mutation can happen until the intent and credentials
        // have been saved together in the device-local registry.
        if queuedBackfill, !saveConnectionsLocked(connections) { return }
        var acknowledged = false
        for index in connections.indices where connections[index].pendingSyncUpdatedAt != nil {
            if backendPublisher.publish(connections[index]) == .published {
                connections[index].syncUpdatedAt = connections[index].pendingSyncUpdatedAt
                connections[index].pendingSyncUpdatedAt = nil
                acknowledged = true
            }
        }
        // A failed acknowledgement save is safe: the exact same pending
        // clock survives, and an equal shared clock needs no second write.
        if acknowledged { saveConnectionsLocked(connections) }
    }
}

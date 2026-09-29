import Foundation

extension PersistenceManager {
    private static let publicationSuppressionsKey = "backendPublicationSuppressions"
    private static let publicationRemovalsKey = "backendPublicationRemovals"

    /// Non-secret observation journal, separate from the credential blob.
    /// Remembering a winning remote removal must survive a local Keychain
    /// save failure, relaunch, and eventual iCloud tombstone purge.
    func suppressedPublicationClock(id: UUID) -> Double? {
        publicationClocks(forKey: Self.publicationSuppressionsKey)[id.uuidString]
    }

    private func publicationClocks(forKey key: String) -> [String: Double] {
        defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    private func suppressPublication(id: UUID, record: SyncedBackendRecord) {
        var clocks = publicationClocks(forKey: Self.publicationSuppressionsKey)
        clocks[id.uuidString] = max(clocks[id.uuidString] ?? record.updatedAt, record.updatedAt)
        defaults.set(clocks, forKey: Self.publicationSuppressionsKey)
        if record.deleted {
            var removals = publicationClocks(forKey: Self.publicationRemovalsKey)
            removals[id.uuidString] = max(removals[id.uuidString] ?? record.updatedAt, record.updatedAt)
            defaults.set(removals, forKey: Self.publicationRemovalsKey)
        }
    }

    private func routePublicationAllowed(_ connection: StoredConnection) -> Bool {
        guard let paired = connection.localPairingSyncClock else { return false }
        let removed = publicationClocks(forKey: Self.publicationRemovalsKey)[connection.id.uuidString]
        return removed.map { $0 < paired } ?? true
    }

    /// Save this route intent atomically with the observed route. Unlike a
    /// deliberate re-pair, this must not authorize recreation after removal.
    func queueRoutePublication(_ connection: inout StoredConnection, previousRoute: String?, newRoute: String? = nil) {
        if connection.invitedPersonKey != nil {
            queueInvitedRoutePublication(&connection, newRoute: newRoute)
            return
        }
        guard connection.principal?.isOwner == true, let backendPublisher, routePublicationAllowed(connection) else { return }
        let previous = connection.pendingRoutePublication
        let clock = backendPublisher.routeClock(for: connection)
        let route = SyncedBackendPayload.tunnelAddress(newRoute)
        let tunnelClock: Double?
        if route != nil {
            tunnelClock = clock
        } else if let previous, previous.tcAddress != nil {
            tunnelClock = previous.tcUpdatedAt ?? previous.updatedAt
        } else {
            tunnelClock = nil
        }
        connection.pendingRoutePublication = PendingBackendRoutePublication(
            updatedAt: clock,
            hosts: connection.server.hosts,
            tcAddress: route ?? previous?.tcAddress,
            tcUpdatedAt: tunnelClock,
            previousTcAddress: previous?.tcAddress != nil ? previous?.previousTcAddress : previousRoute
        )
    }

    /// One attempt per pending backend per pairing/foreground opportunity.
    /// Backfill uses the original pairing time, never today's clock, so an
    /// old installation cannot revive a newer shared removal or edit.
    func publishPendingBackends() {
        publishPendingInvitedSessions()
        guard backendPublisher != nil, var connections = loadConnectionsWithOutcome().connections else { return }
        var queuedBackfill = false
        for index in connections.indices where connections[index].principal?.isOwner == true
            && connections[index].syncUpdatedAt == nil
            && connections[index].pendingSyncUpdatedAt == nil {
            connections[index].pendingSyncUpdatedAt = connections[index].server.pairedAt.timeIntervalSince1970 * 1000 // swiftlint:disable:this no_magic_numbers
            connections[index].localPairingSyncClock = connections[index].pendingSyncUpdatedAt
            queuedBackfill = true
        }
        // No shared mutation can happen until the intent and credentials
        // have been saved together in the device-local registry.
        if queuedBackfill, !saveConnectionsLocked(connections) { return }
        var acknowledged = false
        for index in connections.indices where connections[index].principal?.isOwner == true {
            if publishPairing(&connections[index]) { acknowledged = true }
            if publishRoutes(&connections[index]) { acknowledged = true }
        }
        // A failed acknowledgement save is safe: the exact same pending
        // clock survives, and an equal shared clock needs no second write.
        if acknowledged { saveConnectionsLocked(connections) }
    }

    private func publishPairing(_ connection: inout StoredConnection) -> Bool {
        guard let backendPublisher, let pending = connection.pendingSyncUpdatedAt else { return false }
        if let suppressed = suppressedPublicationClock(id: connection.id), suppressed >= pending { return false }
        switch backendPublisher.publish(connection) {
        case .published:
            connection.syncUpdatedAt = pending
            connection.pendingSyncUpdatedAt = nil
            return true
        case .superseded(let record):
            suppressPublication(id: connection.id, record: record)
        case .retry:
            break
        }
        return false
    }

    private func publishRoutes(_ connection: inout StoredConnection) -> Bool {
        // A route patch must not race a still-pending credential rotation and
        // give that older shared token a clock newer than the deliberate edit.
        guard let backendPublisher, connection.pendingSyncUpdatedAt == nil,
              connection.pendingRoutePublication != nil else { return false }
        if routePublicationAllowed(connection) {
            switch backendPublisher.publishRoutes(connection) {
            case .published:
                break
            case .superseded(let record):
                suppressPublication(id: connection.id, record: record)
            case .retry:
                return false
            }
        }
        connection.pendingRoutePublication = nil
        // Leave the import clock alone: the patched row may contain newer
        // shared credentials/labels that still need to reach the live cache.
        return true
    }
}

#if os(iOS)
import Foundation

/// One machine linked to the push relay for this phone.
nonisolated struct RelayLink: Codable, Equatable, Sendable {
    /// The phone-local `StoredConnection.id` for the machine.
    let connectionId: UUID
    let daemonId: String
    let relayURL: URL
}

/// What the phone knows about its relay registration, and the decisions that
/// follow from it. Persisted as JSON in `UserDefaults`.
nonisolated struct RelayLinkState: Codable, Equatable, Sendable {
    static let defaultsKey = "pushRelayLinkState"

    var links: [RelayLink] = []
    /// The device description the relay last accepted; nil before the first link.
    var sentDevice: RelayDeviceInfo?

    /// With any machine linked, the relay owns the Live Activity and the app
    /// stops writing it.
    var isRelayDriven: Bool { !links.isEmpty }

    /// One phone talks to one relay: the first link picks it.
    var relayURL: URL? { links.first?.relayURL }

    func link(for connectionId: UUID) -> RelayLink? {
        links.first { $0.connectionId == connectionId }
    }

    /// Link a connected machine once, while Live Activities are on. Machines
    /// that could not link (an older intentd) are not asked again this run.
    func shouldLink(connectionId: UUID, enabled: Bool, connected: Bool, declined: Set<UUID>) -> Bool {
        enabled && connected && link(for: connectionId) == nil && !declined.contains(connectionId)
    }

    func accepts(relayURL url: URL) -> Bool {
        relayURL.map { $0 == url } ?? true
    }

    /// Links whose saved connection is gone.
    func staleLinks(savedConnectionIds: Set<UUID>) -> [RelayLink] {
        links.filter { !savedConnectionIds.contains($0.connectionId) }
    }

    /// The device description to PATCH, or nil when the relay already has it
    /// (or no machine is linked yet, so the next registration carries it).
    func devicePatch(for current: RelayDeviceInfo) -> RelayDeviceInfo? {
        guard isRelayDriven, current != sentDevice else { return nil }
        return current
    }

    /// The relay keys a link by daemon, so a re-paired machine replaces its old link.
    mutating func record(_ link: RelayLink) {
        links.removeAll { $0.connectionId == link.connectionId || $0.daemonId == link.daemonId }
        links.append(link)
    }

    mutating func remove(connectionId: UUID) {
        links.removeAll { $0.connectionId == connectionId }
    }

    static func load(from defaults: UserDefaults) -> Self {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
#endif

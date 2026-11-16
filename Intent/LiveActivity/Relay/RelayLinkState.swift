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
    /// The only relay the phone sends its push tokens to. A machine names the
    /// relay in `push.createLink`, so any other origin is refused: a hostile
    /// machine could otherwise collect the tokens and push through the real relay.
    static let trustedRelayHost = "push.intentapp.dev"

    var links: [RelayLink] = []
    /// The device description the relay last accepted; nil before the first link.
    var sentDevice: RelayDeviceInfo?
    /// Forgotten machines whose relay link is not confirmed gone yet.
    var pendingUnlinks: [RelayLink] = []

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
        Self.isTrustedRelay(url) && (relayURL.map { $0 == url } ?? true)
    }

    /// `https://push.intentapp.dev` exactly: no port, user, path, query or fragment.
    static func isTrustedRelay(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https"
            && parts.host?.lowercased() == trustedRelayHost
            && parts.port == nil
            && parts.user == nil
            && parts.password == nil
            && (parts.path.isEmpty || parts.path == "/")
            && parts.query == nil
            && parts.fragment == nil
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
        pendingUnlinks.removeAll { $0.daemonId == link.daemonId }
        links.append(link)
    }

    /// The machine was forgotten: stop using its link and keep it until the
    /// relay confirms the unlink.
    mutating func queueUnlink(connectionId: UUID) {
        guard let link = link(for: connectionId) else { return }
        links.removeAll { $0.connectionId == connectionId }
        queueUnlink(link)
    }

    mutating func queueUnlink(_ link: RelayLink) {
        guard !pendingUnlinks.contains(where: { $0.daemonId == link.daemonId }) else { return }
        pendingUnlinks.append(link)
    }

    mutating func unlinkConfirmed(daemonId: String) {
        pendingUnlinks.removeAll { $0.daemonId == daemonId }
    }

    /// Links saved before the relay check (or to any other relay) are dropped,
    /// so no further tokens go there and honest machines can link again.
    static func load(from defaults: UserDefaults) -> Self {
        let saved = defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
        var state = saved ?? Self()
        state.links.removeAll { !isTrustedRelay($0.relayURL) }
        state.pendingUnlinks.removeAll { !isTrustedRelay($0.relayURL) }
        return state
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
/// State saved before `pendingUnlinks` existed still decodes.
extension RelayLinkState {
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        links = try container.decodeIfPresent([RelayLink].self, forKey: .links) ?? []
        sentDevice = try container.decodeIfPresent(RelayDeviceInfo.self, forKey: .sentDevice)
        pendingUnlinks = try container.decodeIfPresent([RelayLink].self, forKey: .pendingUnlinks) ?? []
    }
}
#endif

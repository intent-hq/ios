#if os(iOS)
import Foundation

nonisolated struct RelayLink: Codable, Equatable, Sendable {
    let connectionId: UUID
    let daemonId: String
    let relayURL: URL
}

nonisolated struct RelayLinkState: Codable, Equatable, Sendable {
    static let defaultsKey = "pushRelayLinkState"
    static let trustedRelayHost = "push.intentapp.dev"

    var links: [RelayLink] = []
    var sentDevice: RelayDeviceInfo?
    var pendingUnlinks: [RelayLink] = []

    var isRelayDriven: Bool { !links.isEmpty }

    var relayURL: URL? { links.first?.relayURL }

    func link(for connectionId: UUID) -> RelayLink? {
        links.first { $0.connectionId == connectionId }
    }

    func shouldLink(connectionId: UUID, enabled: Bool, connected: Bool, declined: Set<UUID>) -> Bool {
        enabled && connected && link(for: connectionId) == nil && !declined.contains(connectionId)
    }

    func accepts(relayURL url: URL) -> Bool {
        Self.isTrustedRelay(url) && (relayURL.map { $0 == url } ?? true)
    }

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

    func staleLinks(savedConnectionIds: Set<UUID>) -> [RelayLink] {
        links.filter { !savedConnectionIds.contains($0.connectionId) }
    }

    func devicePatch(for current: RelayDeviceInfo) -> RelayDeviceInfo? {
        guard isRelayDriven, current != sentDevice else { return nil }
        return current
    }

    mutating func record(_ link: RelayLink) {
        links.removeAll { $0.connectionId == link.connectionId || $0.daemonId == link.daemonId }
        pendingUnlinks.removeAll { $0.daemonId == link.daemonId }
        links.append(link)
    }

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
extension RelayLinkState {
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        links = try container.decodeIfPresent([RelayLink].self, forKey: .links) ?? []
        sentDevice = try container.decodeIfPresent(RelayDeviceInfo.self, forKey: .sentDevice)
        pendingUnlinks = try container.decodeIfPresent([RelayLink].self, forKey: .pendingUnlinks) ?? []
    }
}
#endif

import Foundation

/// A snapshot from the admitted socket's hello, never persisted with a saved host or person.
nonisolated struct ConnectionCapabilities: Equatable, Sendable {
    let protocolVersion: String?
    let scriptMonitorsVersion: Int?
    let scriptActiveListsVersion: Int?
    private(set) var scriptMonitorsDisabled = false

    static let unknown = Self(protocolVersion: nil, scriptMonitorsVersion: nil, scriptActiveListsVersion: nil)

    /// Gated only on the advertised capabilities, never on a protocol-version maximum: the
    /// protocol major moves for unrelated changes (protocol 15 hid monitors, intent-hq/intent#7206).
    /// A breaking change to these methods changes the capability values instead.
    var supportsScriptMonitors: Bool {
        !scriptMonitorsDisabled && scriptMonitorsVersion == 2 && scriptActiveListsVersion == 1
    }

    func disablingScriptMonitors() -> Self {
        var result = self
        result.scriptMonitorsDisabled = true
        return result
    }
}

nonisolated extension ConnectionCapabilities {
    init(hello: Any) {
        let server = (hello as? [String: Any])?["server"] as? [String: Any]
        let capabilities = server?["capabilities"] as? [String: Any]
        protocolVersion = server?["protocolVersion"] as? String
        scriptMonitorsVersion = Self.integer(capabilities?["scriptMonitors"])
        scriptActiveListsVersion = Self.integer(capabilities?["scriptActiveLists"])
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = ConnectionPrincipal.number(value), number.isFinite,
              number >= 0, number <= ConnectionPrincipal.maximumClock,
              number.rounded(.down) == number else { return nil }
        return Int(number)
    }
}

/// Carries identity and capabilities from the same candidate, before socket adoption.
nonisolated struct ConnectionHandshake: Equatable, Sendable {
    let principal: ConnectionPrincipal
    let capabilities: ConnectionCapabilities
}

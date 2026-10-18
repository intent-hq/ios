import Foundation

/// A snapshot from the admitted socket's hello, never persisted with a saved host or person.
nonisolated struct ConnectionCapabilities: Equatable, Sendable {
    let protocolVersion: String?
    let scriptMonitorsVersion: Int?
    let scriptActiveListsVersion: Int?
    private(set) var scriptMonitorsDisabled = false

    static let unknown = Self(protocolVersion: nil, scriptMonitorsVersion: nil, scriptActiveListsVersion: nil)
    private static let supportedScriptProtocolMajor = 14

    var supportsScriptMonitors: Bool {
        guard !scriptMonitorsDisabled, scriptMonitorsVersion == 2, scriptActiveListsVersion == 1,
              let protocolVersion else { return false }
        let parts = protocolVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ part in !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } }),
              let major = Int(parts[0]), Int(parts[1]) != nil else { return false }
        // No general iOS protocol-range negotiation exists yet. Admit only the implemented
        // major's additive minor versions; a future breaking major needs an explicit review.
        return major == Self.supportedScriptProtocolMajor
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

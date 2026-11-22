import Foundation

nonisolated struct ConnectionCapabilities: Equatable, Sendable {
    let protocolVersion: String?
    let scriptMonitorsVersion: Int?
    let scriptActiveListsVersion: Int?
    var collaborationIdentityVersion: Int?
    var conversationGoalVersion: Int?
    private(set) var scriptMonitorsDisabled = false

    static let unknown = Self(protocolVersion: nil, scriptMonitorsVersion: nil, scriptActiveListsVersion: nil)

    var supportsCollaborationIdentity: Bool { collaborationIdentityVersion == 1 }

    var supportsConversationGoal: Bool { conversationGoalVersion == 1 }

    var supportsIdentitySeam: Bool { Self.protocolVersion(protocolVersion, atLeast: Self.identitySeamVersion) }

    private static let identitySeamMajor = 10
    private static let identitySeamMinor = 8
    private static let identitySeamVersion = (major: identitySeamMajor, minor: identitySeamMinor)

    nonisolated static func protocolVersion(_ version: String?, atLeast minimum: (major: Int, minor: Int)) -> Bool {
        guard let version else { return false }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ part in !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } }),
              let major = Int(parts[0]), let minor = Int(parts[1]) else { return false }
        return major > minimum.major || (major == minimum.major && minor >= minimum.minor)
    }

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
        collaborationIdentityVersion = Self.integer(capabilities?["collaborationIdentity"])
        conversationGoalVersion = Self.integer(capabilities?["conversationGoal"])
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = ConnectionPrincipal.number(value), number.isFinite,
              number >= 0, number <= ConnectionPrincipal.maximumClock,
              number.rounded(.down) == number else { return nil }
        return Int(number)
    }
}

nonisolated struct ConnectionHandshake: Equatable, Sendable {
    let principal: ConnectionPrincipal
    let capabilities: ConnectionCapabilities
}

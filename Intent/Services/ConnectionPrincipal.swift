import Foundation
import UIKit

/// Current authority comes only from the admitted socket. Saved copies are
/// classification/provenance for persistence, never permission to act offline.
nonisolated struct ConnectionPrincipal: Codable, Equatable, Sendable {
    enum HostRole: String, Codable, Sendable {
        case guest
        case member
        case owner
    }

    let id: String
    let hostRole: HostRole
    let revision: Double?
    let login: String?
    let displayName: String?

    static let demoOwner = Self(id: "demo-owner", hostRole: .owner, revision: nil, login: nil, displayName: nil)

    var canManageWorkspaces: Bool { hostRole == .owner || hostRole == .member }
    var isOwner: Bool { hostRole == .owner }

    enum AdmissionError: LocalizedError {
        case incompatible
        case personChanged
        case timedOut

        var errorDescription: String? {
            switch self {
            case .incompatible: "The host did not return a valid identity and access level. Please reconnect after updating the host."
            case .personChanged: "This connection belongs to a different person. Pair again to choose that person."
            case .timedOut: "The host did not confirm your identity in time. Please reconnect."
            }
        }
    }

    static func parse(_ value: Any, hello: Any) throws -> Self {
        guard let row = value as? [String: Any], let id = row["id"] as? String, !id.isEmpty,
              let administrator = boolean(row["isAdministrator"]),
              let hello = hello as? [String: Any], let server = hello["server"] as? [String: Any],
              let capabilities = server["capabilities"] as? [String: Any] else { throw AdmissionError.incompatible }
        let supported = number(capabilities["hostMembership"]) == 1
        let role: HostRole
        if let raw = row["hostRole"] {
            guard let name = raw as? String, let known = HostRole(rawValue: name),
                  (known == .owner) == administrator,
                  known != .member || supported else { throw AdmissionError.incompatible }
            role = known
        } else {
            guard !supported else { throw AdmissionError.incompatible }
            role = administrator ? .owner : .guest
        }
        let revision = number(row["hostMembershipRevision"])
        if supported, !validClock(revision) { throw AdmissionError.incompatible }
        return Self(id: id, hostRole: role, revision: revision, login: row["login"] as? String, displayName: row["displayName"] as? String)
    }

    static func samePerson(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }

    static func isRevocation(_ error: Error) -> Bool {
        let failure = error as NSError
        let rpcCode = -32_003
        let closeCode = 4001
        if failure.domain == "WebSocket", failure.code == rpcCode,
           failure.userInfo[NSError.intentErrorDataCodeKey] as? String == "access-revoked" { return true }
        if case WebSocketTransportError.disconnected(_, closeCode, "credential revoked") = error { return true }
        return false
    }

    static func validClock(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value.isFinite && value >= 0 && value <= maximumClock && value.rounded(.down) == value
    }

    static let maximumClock: Double = 9_007_199_254_740_991

    static func number(_ value: Any?) -> Double? {
        // NSNumber preserves CFBoolean identity so JSON booleans cannot be treated as numbers.
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil } // swiftlint:disable:this legacy_objc_type
        return value.doubleValue
    }

    // nil means a missing or invalid JSON boolean, distinct from a valid false value.
    static func boolean(_ value: Any?) -> Bool? { // swiftlint:disable:this discouraged_optional_boolean
        // NSNumber preserves CFBoolean identity so numeric JSON values cannot be treated as booleans.
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil } // swiftlint:disable:this legacy_objc_type
        return value.boolValue
    }
}

/// One local installation ID is shared by its windows and hosts, independently
/// of every person's bearer. Never persist the server's principal-prefixed echo.
enum PairingClientIdentity {
    static func identifier(defaults: UserDefaults = .standard) -> String {
        let key = "pairingClientId"
        if let saved = defaults.string(forKey: key), UUID(uuidString: saved) != nil { return saved }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: key)
        return created
    }

    static func parameters(defaults: UserDefaults = .standard, browserNavigation: Bool = false) -> [String: Any] {
        [
            "clientId": identifier(defaults: defaults), "name": "Intent", "deviceKind": deviceKind,
            "capabilities": ["browserNavigation": browserNavigation, "browserExec": false]
        ]
    }

    private static var deviceKind: String {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: "tablet"
        case .vision: "headset"
        default: "phone"
        }
    }
}

extension SessionConnectionManaging {
    var currentPrincipal: ConnectionPrincipal? { nil }

    func confirmedPrincipal() async throws -> ConnectionPrincipal {
        if let currentPrincipal { return currentPrincipal }
        let hello = try await request("client.hello", params: PairingClientIdentity.parameters())
        let value = try await request("principal.me")
        try Task.checkCancellation()
        return try ConnectionPrincipal.parse(value, hello: hello)
    }
}

#if DEBUG
import Foundation

/// Demo seam for the `intent://invite` join sheet (`--demo-invite=<scenario>`
/// with `--demo-data`): presents a fixture invite and answers the host and
/// own-Mac calls locally, so UI tests and screenshots reach every sheet state
/// without a shared host. Scenarios: `first-join` (confirm, prove through the
/// Mac), `existing-access` (confirm with a login this device has), `no-mac`,
/// `expired`.
enum DemoInviteJoin {
    private static let prefix = "--demo-invite="
    /// SHA-256 fingerprints are 32 bytes.
    private static let fingerprintBytes = 32
    private static let hostFingerprint = String(repeating: "ab", count: fingerprintBytes)
    private static let macFingerprint = String(repeating: "cd", count: fingerprintBytes)
    private static let port = 5181
    /// Long enough for the progress state to render in screenshots.
    static let hostDelay: Duration = .milliseconds(hostDelayMilliseconds)
    static let macDelay: Duration = .milliseconds(macDelayMilliseconds)
    private static let hostDelayMilliseconds = 300
    private static let macDelayMilliseconds = 100

    static var scenario: String? {
        guard DemoMode.isEnabled else { return nil }
        return LaunchOptions.current.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    static let link = InviteLink(
        scope: .workspace,
        hosts: [],
        port: port,
        fingerprint: hostFingerprint,
        tcAddress: "tc1-demo-host",
        inviteId: "demo-invite",
        secret: "demo-secret"
    )

    /// Opens the fixture invite once the first screen is routed.
    @MainActor
    static func present(_ coordinator: AppCoordinator) {
        guard scenario != nil, coordinator.pendingDeepLink == nil, let url = link.url else { return }
        coordinator.handleIncomingURL(url)
    }

    @MainActor
    static func environment(open: @escaping (StoredConnection, String?) -> Void) -> InviteJoinEnvironment? {
        guard let scenario else { return nil }
        return InviteJoinEnvironment(
            openTransport: { _ in DemoInviteTransport(scenario: scenario) },
            savedConnections: { connections(for: scenario) },
            openOwnDaemon: { _ in DemoOwnMac() },
            saveCredential: { _, credential in connection(macFingerprint, role: .guest, token: credential.token, name: "Studio Mac") },
            open: open
        )
    }

    private static func connections(for scenario: String) -> [StoredConnection] {
        switch scenario {
        case "existing-access": [connection(hostFingerprint, role: .guest, token: "demo-guest", name: "Studio Mac")]
        case "no-mac": []
        default: [connection(macFingerprint, role: .owner, token: "demo-owner", name: "Ada's MacBook Pro")]
        }
    }

    private static func connection(_ fingerprint: String, role: ConnectionPrincipal.HostRole, token: String, name: String) -> StoredConnection {
        var connection = StoredConnection(
            id: UUID(),
            server: PairedServer(hosts: [], port: port, name: name, pairedAt: Date(), certFingerprint: fingerprint, tcAddress: "tc1-demo"),
            token: token,
            displayName: name
        )
        connection.principal = ConnectionPrincipal(id: "demo-\(role.rawValue)", hostRole: role, revision: nil, login: "ada", displayName: "Ada")
        return connection
    }
}

nonisolated private struct DemoInviteTransport: InviteTransport {
    let scenario: String
    let routeLabel = ConnectionManager.tunnelCandidateLabel

    func call(_ method: String, params _: [String: Any], timeout _: Duration) async throws -> Any {
        try await Task.sleep(for: DemoInviteJoin.hostDelay)
        if scenario == "expired" { throw InviteFailure.refused("invite-expired") }
        var preview: [String: Any] = [
            "workspaceId": "ws-demo-shared", "workspaceTitle": "Billing revamp",
            "prettyHostname": "Studio Mac", "pinIdentity": NSNull()
        ]
        switch method {
        case "invite.challenge":
            preview["nonce"] = "demo-nonce"
            return preview
        case "invite.accept", "invite.prove":
            return ["status": "authorized", "token": "demo-guest", "principalId": "demo-guest", "login": "ada", "workspaceId": "ws-demo-shared"]
        default:
            return preview
        }
    }

    func close() async {
        await Task.yield()
    }
}

@MainActor
private final class DemoOwnMac: InviteOwnDaemon {
    let supportsCollaborationIdentity = false
    let supportsIdentitySeam = true

    func request(_ method: String, params _: [String: Any]) async throws -> Any {
        try await Task.sleep(for: DemoInviteJoin.macDelay)
        switch method {
        case "principal.me": return ["identity": ["provider": "github", "host": "github.com", "externalUserId": "4242"]]
        case "github.getUser": return ["user": ["login": "ada", "id": "4242"]]
        case "github.identityProof.create": return ["gistId": "demo-gist", "login": "ada"]
        default: return ["ok": true]
        }
    }

    func close() {}
}
#endif

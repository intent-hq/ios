import Foundation

/// An actionable `intent://` deep link awaiting explicit user confirmation
/// before anything is sent: a pairing link (DeepLinkPairingView) or a
/// workspace invite (InviteJoinView). Unlike the in-app camera scan, a deep
/// link can be triggered by any web page.
struct DeepLinkRequest: Identifiable, Equatable {
    enum Target: Equatable {
        case pair(PairingPayload)
        case invite(InviteLink)
    }

    let id = UUID()
    let target: Target

    var pairingPayload: PairingPayload? {
        if case .pair(let payload) = target { return payload }
        return nil
    }

    var inviteLink: InviteLink? {
        if case .invite(let link) = target { return link }
        return nil
    }
}

extension AppCoordinator {
    // MARK: - Deep links (intent:// URLs)

    /// Entry point for `intent://` URLs (IntentApp.onOpenURL). Two kinds are
    /// actionable, each behind a confirmation before anything is sent:
    /// `intent://pair` (DeepLinkPairingView) and `intent://invite`, a shared
    /// workspace (InviteJoinView). Every other or malformed `intent://` URL is
    /// ignored without disturbing app state. The URL itself is never logged:
    /// pair links carry the auth token and invite links the invite secret.
    func handleIncomingURL(_ url: URL) {
        let target: DeepLinkRequest.Target
        if let payload = PairingPayload.parse(url.absoluteString) {
            target = .pair(payload)
        } else if let link = InviteLink.parse(url) {
            target = .invite(link)
        } else {
            if url.scheme == "intent", url.host == "pair" { PairingDiagnostics.invalidInput() }
            if InviteLink.isInviteURL(url) {
                AppLog.app.info("[AppCoordinator] Ignoring malformed invite link")
            } else {
                AppLog.app.info("[AppCoordinator] Ignoring unsupported deep link")
            }
            return
        }
        guard routingState.hasLoadCompleted else {
            // Cold start: the URL can arrive before onLoadComplete has routed
            // to the first screen — stash it and surface it after load.
            routingState.stashedDeepLink = target
            return
        }
        pendingDeepLink = DeepLinkRequest(target: target)
    }

    /// An invite was joined, or this device already had access to the host:
    /// open the host, landing in the shared workspace when the invite named one.
    func onInviteJoined(_ connection: StoredConnection, workspaceId: String?) {
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        if backendID?.connectionID == connection.id, currentScreen.supportsConnectionLossOverlay {
            // Already showing this host: navigate in place, no reconnect.
            pendingDeepLink = nil
            if let workspaceId { onSelectWorkspace(workspaceId) }
            return
        }
        onDeepLinkPaired(connection)
        if let workspaceId {
            // Initial routing restores this screen once the host connects.
            // Saved after the switch, which starts that host at its list.
            dependencies.persistence.saveLastScreen(
                .init(screen: "workspaceDetail", workspaceId: workspaceId, agentId: nil, agentName: nil, noteId: nil, noteTitle: nil),
                for: connection.id
            )
        }
    }

    /// The production join environment for this window. Saving dials the
    /// window's own session connection, exactly like a deep-link pairing.
    func inviteJoinEnvironment(connection: any SessionConnectionManaging) -> InviteJoinEnvironment {
        #if DEBUG
        if let demo = DemoInviteJoin.environment(open: { [weak self] _, _ in self?.pendingDeepLink = nil }) { return demo }
        #endif
        let persistence = dependencies.persistence
        let registry = dependencies.sessionRegistry
        let dialer = connection.tunnelDialer
        return InviteJoinEnvironment(
            openTransport: { link in try await InviteSocket.open(link, dialer: dialer) },
            savedConnections: { persistence.loadConnections() },
            openOwnDaemon: { mac in
                try await OwnMacConnection.open(mac, live: registry.session(for: BackendID(mac.id))?.connection, persistence: persistence)
            },
            saveCredential: { link, credential in
                let payload = PairingPayload(
                    hosts: link.hosts,
                    port: link.port,
                    token: credential.token,
                    certFingerprint: link.fingerprint,
                    tcAddress: link.tcAddress
                )
                return try await PairingFlow.connect(
                    payload: payload,
                    certFingerprint: link.fingerprint,
                    connectionManager: connection,
                    persistence: persistence
                )
            },
            open: { [weak self] stored, workspaceId in self?.onInviteJoined(stored, workspaceId: workspaceId) }
        )
    }
}

/// The person's own Mac, used to read their forge account and publish the
/// identity proof. Reuses a live window connection to it when there is one;
/// otherwise dials a short-lived connection that `close()` drops.
@MainActor
final class OwnMacConnection: InviteOwnDaemon {
    private static let requestTimeout: TimeInterval = 60

    private let connection: any SessionConnectionManaging
    private let ownsConnection: Bool

    private init(connection: any SessionConnectionManaging, ownsConnection: Bool) {
        self.connection = connection
        self.ownsConnection = ownsConnection
    }

    var supportsCollaborationIdentity: Bool { connection.capabilities.supportsCollaborationIdentity }
    var supportsIdentitySeam: Bool { connection.capabilities.supportsIdentitySeam }

    static func open(
        _ mac: StoredConnection,
        live: (any SessionConnectionManaging)?,
        persistence: PersistenceManager
    ) async throws -> OwnMacConnection {
        if let live, live.connectionState == .connected, live.currentPrincipal?.isOwner == true {
            return OwnMacConnection(connection: live, ownsConnection: false)
        }
        let manager = ConnectionManager(persistence: persistence)
        do {
            try await manager.connect(
                hosts: mac.server.hosts,
                port: mac.server.port,
                token: mac.token,
                certFingerprint: mac.server.certFingerprint,
                tcAddress: mac.server.tcAddress
            )
            // Only the Mac's owner may publish a proof for this person.
            guard try await manager.confirmedPrincipal().isOwner else { throw InviteProofFailure.unavailable }
        } catch {
            manager.disconnect()
            throw error
        }
        return OwnMacConnection(connection: manager, ownsConnection: true)
    }

    func request(_ method: String, params: [String: Any]) async throws -> Any {
        try await connection.request(method, params: params, timeout: Self.requestTimeout)
    }

    func close() {
        if ownsConnection { connection.disconnect() }
    }
}

import Foundation

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
            routingState.stashedDeepLink = target
            return
        }
        pendingDeepLink = DeepLinkRequest(target: target)
    }

    func onInviteJoined(_ connection: StoredConnection, workspaceId: String?) {
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        if backendID?.connectionID == connection.id, currentScreen.supportsConnectionLossOverlay {
            pendingDeepLink = nil
            if let workspaceId { onSelectWorkspace(workspaceId) }
            return
        }
        onDeepLinkPaired(connection)
        if let workspaceId {
            dependencies.persistence.saveLastScreen(
                .init(screen: "workspaceDetail", workspaceId: workspaceId, agentId: nil, agentName: nil, noteId: nil, noteTitle: nil),
                for: connection.id
            )
        }
    }

    func inviteJoinEnvironment(connection: any SessionConnectionManaging) -> InviteJoinEnvironment {
        #if DEBUG
        if let demo = DemoInviteJoin.environment(open: { [weak self] _, _ in self?.pendingDeepLink = nil }) { return demo }
        #endif
        let persistence = dependencies.persistence
        let dialer = connection.tunnelDialer
        return InviteJoinEnvironment(
            openTransport: { link in try await InviteSocket.open(link, dialer: dialer) },
            savedConnections: { persistence.loadConnections() },
            openOwnDaemon: { mac in try await OwnMacConnection.open(mac, persistence: persistence) },
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

@MainActor
final class OwnMacConnection: InviteOwnDaemon {
    private static let requestTimeout: TimeInterval = 60

    private let connection: ConnectionManager

    private init(connection: ConnectionManager) {
        self.connection = connection
    }

    var supportsCollaborationIdentity: Bool { connection.capabilities.supportsCollaborationIdentity }
    var supportsIdentitySeam: Bool { connection.capabilities.supportsIdentitySeam }

    static func open(_ mac: StoredConnection, persistence: PersistenceManager) async throws -> OwnMacConnection {
        let manager = ConnectionManager(persistence: persistence)
        do {
            try await manager.connect(
                hosts: mac.server.hosts,
                port: mac.server.port,
                token: mac.token,
                certFingerprint: mac.server.certFingerprint,
                tcAddress: mac.server.tcAddress
            )
            guard try await manager.confirmedPrincipal().isOwner else { throw InviteProofFailure.unavailable }
        } catch {
            manager.disconnect()
            throw error
        }
        return OwnMacConnection(connection: manager)
    }

    func request(_ method: String, params: [String: Any]) async throws -> Any {
        try await connection.request(method, params: params, timeout: Self.requestTimeout)
    }

    func close() {
        connection.disconnect()
    }
}

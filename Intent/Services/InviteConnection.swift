import Foundation
import os

// The guest side of the host's unauthenticated `/invite` endpoint (protocol
// §5.48 "Joining by invite"). It serves exactly `invite.inspect`,
// `invite.accept`, `invite.challenge` and `invite.prove`, with no hello. Every
// request carries the invite secret, so request and response text is never
// logged, and server-authored error text is dropped: only the documented
// `error.data.code` values leave this file.

/// A forge account named by its stable id (`{ provider, host, externalUserId }`).
nonisolated struct InviteIdentity: Equatable, Sendable {
    static let githubHost = "github.com"

    let provider: String
    let host: String
    let externalUserId: String

    var isGitHub: Bool { provider == "github" }
    var json: [String: Any] { ["provider": provider, "host": host, "externalUserId": externalUserId] }

    /// Validates the canonical wire form and never repairs it.
    static func parse(_ value: Any?) -> Self? {
        guard let row = value as? [String: Any],
              let provider = row["provider"] as? String, provider == "github" || provider == "gitlab",
              let host = row["host"] as? String,
              let externalUserId = row["externalUserId"] as? String, !externalUserId.isEmpty,
              externalUserId.trimmingCharacters(in: .whitespaces) == externalUserId else { return nil }
        if provider == "github" { return host == githubHost ? Self(provider: provider, host: host, externalUserId: externalUserId) : nil }
        guard let components = URLComponents(string: "https://\(host)"), let parsedHost = components.host,
              !parsedHost.isEmpty, components.path.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              host == parsedHost.lowercased() + (components.port.map { ":\($0)" } ?? "") else { return nil }
        return Self(provider: provider, host: host, externalUserId: externalUserId)
    }
}

/// Which forge account the invite requires.
nonisolated enum InvitePin: Equatable, Sendable {
    case pinned(InviteIdentity)
    /// The host omitted `pinIdentity` (older host): the requirement is unknown.
    case unknown
    /// Explicit `null`: anyone with the link may join.
    case unpinned
}

/// `invite.inspect` / `invite.challenge`: the invite's preview for the consent prompt.
nonisolated struct InvitePreview: Equatable, Sendable {
    let scope: InviteLink.Scope
    let workspaceId: String?
    let workspaceTitle: String?
    /// The host's display name (collaboration name, pretty or plain hostname).
    let hostName: String?
    let pin: InvitePin
    /// Set on `invite.challenge` only: the single-use nonce the proof must carry.
    let nonce: String?

    /// Validates a preview for `scope`; nil when the response does not match.
    static func parse(_ value: Any, scope: InviteLink.Scope, requiresNonce: Bool) -> Self? {
        guard let row = value as? [String: Any] else { return nil }
        let pin: InvitePin
        switch row["pinIdentity"] {
        case .none: pin = .unknown
        case is NSNull: pin = .unpinned
        case let raw?:
            guard let identity = InviteIdentity.parse(raw) else { return nil }
            pin = .pinned(identity)
        }
        let wireScope = row["scope"] as? String
        let role = row["role"] as? String
        let workspaceId = row["workspaceId"] as? String
        let workspaceTitle = row["workspaceTitle"] as? String
        switch scope {
        case .workspace:
            guard row["scope"] == nil || wireScope == "workspace", row["role"] == nil || role == "collaborator",
                  let workspaceId, !workspaceId.isEmpty, workspaceTitle != nil else { return nil }
        case .host:
            guard wireScope == "host", role == "member", case .pinned = pin,
                  row["workspaceId"] == nil, row["workspaceTitle"] == nil else { return nil }
        }
        let nonce = (row["nonce"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if requiresNonce, nonce == nil { return nil }
        let names = [row["collaborationName"], row["prettyHostname"], row["hostname"]]
        let hostName = names.lazy.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return Self(
            scope: scope,
            workspaceId: workspaceId,
            workspaceTitle: workspaceTitle,
            hostName: hostName,
            pin: pin,
            nonce: nonce
        )
    }

    /// A refreshed challenge may change only its nonce.
    func describesSameInvite(as other: Self) -> Bool {
        scope == other.scope && workspaceId == other.workspaceId && workspaceTitle == other.workspaceTitle
            && hostName == other.hostName && pin == other.pin
    }
}

/// `invite.prove` / `invite.accept`: the person's credential for this host, returned once.
nonisolated struct InviteCredential: Equatable, Sendable {
    let token: String
    let principalId: String
    let login: String
    let workspaceId: String?
    let identity: InviteIdentity?

    static func parse(_ value: Any, scope: InviteLink.Scope) -> Self? {
        guard let row = value as? [String: Any], row["status"] as? String == "authorized",
              let token = row["token"] as? String, !token.isEmpty,
              let principalId = row["principalId"] as? String, !principalId.isEmpty,
              let login = row["login"] as? String else { return nil }
        let identity = row["identity"].flatMap(InviteIdentity.parse)
        if row["identity"] != nil, identity == nil { return nil }
        if let hostRole = row["hostRole"], !["member", "guest"].contains(hostRole as? String ?? "") { return nil }
        let workspaceId = row["workspaceId"] as? String
        switch scope {
        case .workspace:
            guard row["scope"] == nil || row["scope"] as? String == "workspace",
                  let workspaceId, !workspaceId.isEmpty else { return nil }
        case .host:
            guard row["scope"] as? String == "host", row["hostRole"] as? String == "member",
                  identity != nil, row["workspaceId"] == nil else { return nil }
        }
        return Self(token: token, principalId: principalId, login: login, workspaceId: workspaceId, identity: identity)
    }
}

/// The proof `invite.prove` names: a GitHub gist, or a snippet on a GitLab instance.
nonisolated struct InviteProof: Equatable, Sendable {
    let provider: String
    let host: String
    let proofId: String
    let login: String

    func proveParams(nonce: String) -> [String: Any] {
        provider == "github"
            ? ["nonce": nonce, "gistId": proofId, "login": login]
            : ["nonce": nonce, "provider": provider, "host": host, "proofId": proofId, "login": login]
    }
}

/// Why an invite step failed, reduced to bounded codes that are safe to log and show.
nonisolated enum InviteFailure: Error, Equatable, Sendable {
    case certificateMismatch
    case connectionClosed
    /// The host answered with a shape this app cannot trust.
    case invalidResponse
    /// A documented `/invite` refusal (`error.data.code`); empty for any other error.
    case refused(String)
    case timedOut
    case tunnelUnavailable
    case unreachable

    static let documentedCodes: Set<String> = [
        "invite-not-found", "invite-expired", "invite-revoked", "invite-redeemed",
        "invite-pin-mismatch", "invite-pin-unknown", "workspace-full", "workspace-archived",
        "credential-invalid", "proof-invalid", "proof-expired", "github-unreachable",
        "identity-unverifiable", "owner-self-join", "github-identity-required", "invite-flow-busy"
    ]

    var refusalCode: String? {
        if case .refused(let code) = self, !code.isEmpty { return code }
        return nil
    }
}

/// One JSON-RPC call over an open `/invite` socket. Abstracted for tests.
nonisolated protocol InviteTransport: Sendable {
    /// Display label of the route that answered (a host, or the tunnel).
    var routeLabel: String { get }

    func call(_ method: String, params: [String: Any], timeout: Duration) async throws -> Any
    func close() async
}

/// The four `/invite` methods with response validation.
nonisolated struct InviteClient: Sendable {
    private static let requestSeconds: Int64 = 30
    /// The host reads the proof back from the forge before answering.
    private static let proveSeconds: Int64 = 60
    static let requestTimeout: Duration = .seconds(requestSeconds)
    static let proveTimeout: Duration = .seconds(proveSeconds)

    let transport: any InviteTransport
    let link: InviteLink

    private var credentials: [String: Any] { ["inviteId": link.inviteId, "secret": link.secret] }

    func inspect() async throws -> InvitePreview {
        let result = try await transport.call("invite.inspect", params: credentials, timeout: Self.requestTimeout)
        guard let preview = InvitePreview.parse(result, scope: link.scope, requiresNonce: false) else { throw InviteFailure.invalidResponse }
        return preview
    }

    func challenge() async throws -> InvitePreview {
        let result = try await transport.call("invite.challenge", params: credentials, timeout: Self.requestTimeout)
        guard let preview = InvitePreview.parse(result, scope: link.scope, requiresNonce: true) else { throw InviteFailure.invalidResponse }
        return preview
    }

    func accept(credential token: String) async throws -> InviteCredential {
        var params = credentials
        params["credential"] = token
        return try credential(from: await transport.call("invite.accept", params: params, timeout: Self.requestTimeout))
    }

    func prove(_ proof: InviteProof, nonce: String) async throws -> InviteCredential {
        let params = credentials.merging(proof.proveParams(nonce: nonce)) { _, new in new }
        return try credential(from: await transport.call("invite.prove", params: params, timeout: Self.proveTimeout))
    }

    private func credential(from result: Any) throws -> InviteCredential {
        guard let credential = InviteCredential.parse(result, scope: link.scope) else { throw InviteFailure.invalidResponse }
        return credential
    }
}

/// A pin-verified `/invite` WebSocket, dialed over the link's direct hosts
/// (legacy links only) and its Tailcat tunnel.
nonisolated final class InviteSocket: InviteTransport {
    let routeLabel: String
    private let connection: RacedConnection
    private let requests = RequestCounter()

    private init(connection: RacedConnection) {
        self.connection = connection
        routeLabel = connection.host
    }

    static func open(_ link: InviteLink, dialer: any TunnelDialing) async throws -> InviteSocket {
        var candidates = link.hosts
        if link.tcAddress != nil { candidates.append(ConnectionManager.tunnelCandidateLabel) }
        let fingerprint = link.fingerprint
        let outcome = await ConnectionManager.raceCandidates(candidates) { candidate in
            if candidate == ConnectionManager.tunnelCandidateLabel, let tcAddress = link.tcAddress {
                return try await ConnectionManager.connectViaTunnel(
                    dialer: dialer,
                    tcAddress: tcAddress,
                    remotePort: link.port,
                    token: "",
                    certFingerprint: fingerprint,
                    endpoint: .invite
                )
            }
            let socket = try await WebSocketConnection.connect(
                host: candidate,
                port: link.port,
                token: "",
                certFingerprint: fingerprint,
                endpoint: .invite
            )
            return RacedConnection(socket: socket, tunnel: nil, host: candidate)
        }
        if let winner = outcome.winner { return InviteSocket(connection: winner) }
        throw Self.failure(outcome.failure, mismatched: !outcome.mismatches.isEmpty)
    }

    private static func failure(_ error: (any Error)?, mismatched: Bool) -> InviteFailure {
        if mismatched { return .certificateMismatch }
        if error is CancellationError { return .connectionClosed }
        if let establishment = error as? TunnelEstablishmentFailure {
            if case let .failed(_, message, _) = establishment.underlyingError as? WebSocketTransportError,
               message == UnavailableTunnelDialer.unavailableMessage { return .tunnelUnavailable }
            return .unreachable
        }
        guard let transport = error as? WebSocketTransportError else { return .unreachable }
        if transport.isCertificateMismatch { return .certificateMismatch }
        if case .timedOut = transport { return .timedOut }
        return .unreachable
    }

    func call(_ method: String, params: [String: Any], timeout: Duration) async throws -> Any {
        let id = requests.next()
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let text = String(data: data, encoding: .utf8) else { throw InviteFailure.invalidResponse }
        let socket = connection.socket
        let frame = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                do {
                    try await socket.send(text)
                    while true {
                        let bytes = Self.bytes(of: try await socket.receive())
                        if Self.frameID(bytes) == id { return bytes }
                    }
                } catch {
                    throw Task.isCancelled ? error : InviteFailure.connectionClosed
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw InviteFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let frame = try await group.next() else { throw InviteFailure.connectionClosed }
            return frame
        }
        guard let result = try Self.response(to: id, in: .data(frame)) else { throw InviteFailure.invalidResponse }
        return result
    }

    private static func bytes(of message: URLSessionWebSocketTask.Message) -> Data {
        switch message {
        case .string(let text): Data(text.utf8)
        case .data(let bytes): bytes
        @unknown default: Data()
        }
    }

    private static func frameID(_ bytes: Data) -> Int? {
        guard let frame = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let id = ConnectionPrincipal.number(frame["id"]) else { return nil }
        return Int(exactly: id)
    }

    /// The result of the response numbered `id`, nil for any other frame.
    /// Errors keep only the documented `error.data.code`.
    static func response(to id: Int, in message: URLSessionWebSocketTask.Message) throws -> Any? {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return nil
        }
        guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ConnectionPrincipal.number(frame["id"]) == Double(id) else { return nil }
        if let error = frame["error"] as? [String: Any] {
            let code = (error["data"] as? [String: Any])?["code"] as? String
            throw InviteFailure.refused(code.flatMap { InviteFailure.documentedCodes.contains($0) ? $0 : nil } ?? "")
        }
        guard let result = frame["result"] else { throw InviteFailure.invalidResponse }
        return result
    }

    func close() async {
        await connection.disconnect()
    }
}

nonisolated private final class RequestCounter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)

    func next() -> Int {
        value.withLock { counter in
            counter += 1
            return counter
        }
    }
}

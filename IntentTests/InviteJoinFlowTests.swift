import Foundation
@testable import Intent
import Testing

/// InviteJoinModel against fake transports: who gets asked what, what is
/// sent to the host, and what is saved and opened.
@MainActor
struct InviteJoinFlowTests {
    static let hostFingerprint = String(repeating: "ab", count: 32)
    static let macFingerprint = String(repeating: "cd", count: 32)
    static let link = InviteLink(
        scope: .workspace,
        hosts: [],
        port: 5181,
        fingerprint: hostFingerprint,
        tcAddress: "tc1-host",
        inviteId: "inv-1",
        secret: "s3cret"
    )
    static let preview: [String: Any] = [
        "workspaceId": "ws-1", "workspaceTitle": "Billing revamp", "prettyHostname": "Studio Mac", "pinIdentity": NSNull()
    ]

    static func connection(_ fingerprint: String, role: ConnectionPrincipal.HostRole, token: String, name: String) -> StoredConnection {
        var connection = StoredConnection(
            id: UUID(),
            server: PairedServer(hosts: [], port: 5181, name: name, pairedAt: Date(), certFingerprint: fingerprint, tcAddress: "tc1"),
            token: token,
            displayName: name
        )
        connection.principal = ConnectionPrincipal(id: "\(name)-principal", hostRole: role, revision: nil, login: "ada", displayName: nil)
        return connection
    }

    final class Recorder {
        var saved: [InviteCredential] = []
        var opened: [(StoredConnection, String?)] = []
        /// Runs as the credential is saved (which dials the new host).
        var onSave: () -> Void = {}
    }

    static func model(
        transport: FakeInviteTransport,
        connections: [StoredConnection],
        recorder: Recorder,
        daemon: FakeOwnDaemon? = nil
    ) -> InviteJoinModel {
        InviteJoinModel(link: link, environment: InviteJoinEnvironment(
            openTransport: { _ in transport },
            savedConnections: { connections },
            openOwnDaemon: { _ in
                guard let daemon else { throw InviteFailure.unreachable }
                return daemon
            },
            saveCredential: { _, credential in
                recorder.onSave()
                recorder.saved.append(credential)
                return Self.connection(Self.hostFingerprint, role: .guest, token: credential.token, name: "joined")
            },
            open: { connection, workspaceId in recorder.opened.append((connection, workspaceId)) }
        ))
    }

    static func waitFor(_ model: InviteJoinModel, _ matches: (InviteJoinModel.Phase) -> Bool) async throws {
        for _ in 0..<500 {
            if matches(model.phase) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out in phase \(model.phase)")
    }

    static func isConfirm(_ phase: InviteJoinModel.Phase) -> Bool {
        if case .confirm = phase { return true }
        return false
    }

    // MARK: - Tests

    @Test func ownerOfTheHostOpensItWithoutJoining() async throws {
        let transport = FakeInviteTransport(responses: ["invite.inspect": .success(Self.preview)])
        let owned = Self.connection(Self.hostFingerprint, role: .owner, token: "owner", name: "studio")
        let recorder = Recorder()
        let model = Self.model(transport: transport, connections: [owned], recorder: recorder)
        model.start()
        try await Self.waitFor(model) { $0 == .finished }
        #expect(recorder.opened.first?.0.id == owned.id)
        #expect(recorder.opened.first?.1 == "ws-1")
        #expect(transport.methods == ["invite.inspect"])
    }

    @Test func returningGuestAcceptsWithItsStoredLoginAfterConfirming() async throws {
        let guest = Self.connection(Self.hostFingerprint, role: .guest, token: "guest-token", name: "studio")
        let transport = FakeInviteTransport(responses: [
            "invite.inspect": .success(Self.preview),
            "invite.accept": .success(["status": "authorized", "token": "guest-token", "principalId": "studio-principal", "login": "ada", "workspaceId": "ws-1"])
        ])
        let recorder = Recorder()
        let model = Self.model(transport: transport, connections: [guest], recorder: recorder)
        model.start()
        try await Self.waitFor(model, Self.isConfirm)
        guard case .confirm(let confirmation) = model.phase else { return }
        #expect(confirmation.method == .existingAccess)
        #expect(confirmation.workspaceTitle == "Billing revamp")
        #expect(confirmation.hostName == "Studio Mac")
        #expect(transport.methods == ["invite.inspect"], "Nothing is redeemed before Join")
        model.answer(true)
        try await Self.waitFor(model) { $0 == .finished }
        #expect(transport.params(of: "invite.accept")["credential"] as? String == "guest-token")
        #expect(recorder.saved.isEmpty, "The same token needs no new record")
        #expect(recorder.opened.first?.0.id == guest.id)
        #expect(recorder.opened.first?.1 == "ws-1")
    }

    @Test func decliningSendsNothingAndFinishes() async throws {
        let guest = Self.connection(Self.hostFingerprint, role: .guest, token: "guest-token", name: "studio")
        let transport = FakeInviteTransport(responses: ["invite.inspect": .success(Self.preview)])
        let recorder = Recorder()
        let model = Self.model(transport: transport, connections: [guest], recorder: recorder)
        model.start()
        try await Self.waitFor(model, Self.isConfirm)
        model.answer(false)
        try await Self.waitFor(model) { $0 == .finished }
        #expect(transport.methods == ["invite.inspect"])
        #expect(recorder.opened.isEmpty)
    }

    @Test func withoutAnOwnMacExplainsHowToJoin() async throws {
        let transport = FakeInviteTransport(responses: ["invite.inspect": .success(Self.preview)])
        let recorder = Recorder()
        let model = Self.model(transport: transport, connections: [], recorder: recorder)
        model.start()
        try await Self.waitFor(model) { $0 == .needsOwnMac }
        #expect(transport.methods == ["invite.inspect"])
    }

    @Test func firstJoinProvesThroughTheOwnMacThenSavesAndCleansUp() async throws {
        var challenge = Self.preview
        challenge["nonce"] = "nonce-1"
        let transport = FakeInviteTransport(responses: [
            "invite.inspect": .success(Self.preview),
            "invite.challenge": .success(challenge),
            "invite.prove": .success(["status": "authorized", "token": "new-token", "principalId": "p-9", "login": "ada", "workspaceId": "ws-1"])
        ])
        let daemon = FakeOwnDaemon(responses: [
            "principal.me": ["identity": ["provider": "github", "host": "github.com", "externalUserId": "42"]],
            "github.getUser": ["user": ["login": "ada", "id": 42]],
            "github.identityProof.create": ["gistId": "gist-1", "login": "ada"],
            "github.identityProof.delete": ["ok": true]
        ])
        let mac = Self.connection(Self.macFingerprint, role: .owner, token: "mac", name: "Ada's MacBook")
        let recorder = Recorder()
        var methodsAtSave: [String] = []
        recorder.onSave = { methodsAtSave = daemon.methods }
        let model = Self.model(transport: transport, connections: [mac], recorder: recorder, daemon: daemon)
        model.start()
        try await Self.waitFor(model, Self.isConfirm)
        guard case .confirm(let confirmation) = model.phase else { return }
        #expect(confirmation.method == .proveOnMac(macName: "Ada's MacBook", providerName: "GitHub"))
        #expect(confirmation.login == "ada")
        #expect(!daemon.methods.contains("github.identityProof.create"), "Nothing is published before Join")
        model.answer(true)
        try await Self.waitFor(model) { $0 == .finished }
        let prove = transport.params(of: "invite.prove")
        #expect(prove["gistId"] as? String == "gist-1")
        #expect(prove["nonce"] as? String == "nonce-1")
        #expect(prove["secret"] as? String == "s3cret")
        #expect(recorder.saved.map(\.token) == ["new-token"])
        #expect(recorder.opened.first?.1 == "ws-1")
        #expect(methodsAtSave.last == "github.identityProof.delete", "The proof is gone before saving dials the new host")
        #expect(daemon.closed)
    }

    @Test func ownMacWithoutAnAccountAsksToSignIn() async throws {
        var challenge = Self.preview
        challenge["nonce"] = "nonce-1"
        let transport = FakeInviteTransport(responses: [
            "invite.inspect": .success(Self.preview),
            "invite.challenge": .success(challenge)
        ])
        let daemon = FakeOwnDaemon(responses: [
            "principal.me": ["identity": NSNull()],
            "github.getUser": ["user": NSNull()],
            "sourceControl.authStatus": ["isConfigured": false]
        ])
        let mac = Self.connection(Self.macFingerprint, role: .owner, token: "mac", name: "Ada's MacBook")
        let model = Self.model(transport: transport, connections: [mac], recorder: Recorder(), daemon: daemon)
        model.start()
        try await Self.waitFor(model) { $0 == .needsSignIn(providerName: "GitHub or GitLab", macName: "Ada's MacBook") }
    }

    @Test func pinnedInviteRefusesADifferentAccount() async throws {
        var challenge = Self.preview
        challenge["nonce"] = "nonce-1"
        challenge["pinIdentity"] = ["provider": "github", "host": "github.com", "externalUserId": "7"]
        var preview = Self.preview
        preview["pinIdentity"] = challenge["pinIdentity"]
        let transport = FakeInviteTransport(responses: [
            "invite.inspect": .success(preview),
            "invite.challenge": .success(challenge)
        ])
        let daemon = FakeOwnDaemon(responses: ["github.getUser": ["user": ["login": "ada", "id": 42]]])
        let mac = Self.connection(Self.macFingerprint, role: .owner, token: "mac", name: "Mac")
        let model = Self.model(transport: transport, connections: [mac], recorder: Recorder(), daemon: daemon)
        model.start()
        try await Self.waitFor(model) { phase in
            if case .failed(let problem) = phase { return problem.message.contains("different GitHub account") }
            return false
        }
        #expect(!daemon.methods.contains("github.identityProof.create"))
    }

    @Test func hostRefusalsBecomePlainLanguageProblems() async throws {
        let transport = FakeInviteTransport(responses: ["invite.inspect": .failure(InviteFailure.refused("invite-expired"))])
        let model = Self.model(transport: transport, connections: [], recorder: Recorder())
        model.start()
        try await Self.waitFor(model) { phase in
            if case .failed(let problem) = phase { return problem.title == "Invite Expired" && !problem.retryable }
            return false
        }
        #expect(transport.closed)
    }

    @Test func onlyTheConfirmedGuestLoginIsPresented() async throws {
        var older = Self.connection(Self.hostFingerprint, role: .guest, token: "other-person", name: "studio")
        older.principal = ConnectionPrincipal(id: "grace", hostRole: .guest, revision: nil, login: "grace", displayName: nil)
        older.lastConnectedAt = .distantPast
        var newer = Self.connection(Self.hostFingerprint, role: .guest, token: "stale", name: "studio")
        newer.lastConnectedAt = Date()
        let transport = FakeInviteTransport(responses: [
            "invite.inspect": .success(Self.preview),
            "invite.accept": .failure(InviteFailure.refused("credential-invalid"))
        ])
        let model = Self.model(transport: transport, connections: [older, newer], recorder: Recorder())
        model.start()
        try await Self.waitFor(model, Self.isConfirm)
        guard case .confirm(let confirmation) = model.phase else { return }
        #expect(confirmation.login == "ada")
        model.answer(true)
        try await Self.waitFor(model) { $0 == .needsOwnMac }
        #expect(transport.methods.filter { $0 == "invite.accept" }.count == 1, "Grace's login is never sent after confirming Ada")
        #expect(transport.params(of: "invite.accept")["credential"] as? String == "stale")
    }

    @Test func invalidStoredLoginFallsBackToTheProof() async throws {
        let guest = Self.connection(Self.hostFingerprint, role: .guest, token: "stale", name: "studio")
        var challenge = Self.preview
        challenge["nonce"] = "nonce-1"
        let transport = FakeInviteTransport(responses: [
            "invite.inspect": .success(Self.preview),
            "invite.accept": .failure(InviteFailure.refused("credential-invalid")),
            "invite.challenge": .success(challenge)
        ])
        let model = Self.model(transport: transport, connections: [guest], recorder: Recorder())
        model.start()
        try await Self.waitFor(model, Self.isConfirm)
        model.answer(true)
        try await Self.waitFor(model) { $0 == .needsOwnMac }
        #expect(transport.methods == ["invite.inspect", "invite.accept"])
    }
}

/// Answers `/invite` calls from a table and records what was sent.
nonisolated final class FakeInviteTransport: InviteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [String: Result<[String: Any], InviteFailure>]
    private var calls: [(String, [String: Any])] = []
    private var isClosed = false
    let routeLabel = "tailcat-tunnel"

    init(responses: [String: Result<[String: Any], InviteFailure>]) {
        self.responses = responses
    }

    var methods: [String] { locked { calls.map(\.0) } }
    var closed: Bool { locked { isClosed } }

    func params(of method: String) -> [String: Any] {
        locked { calls.last { $0.0 == method }?.1 ?? [:] }
    }

    func call(_ method: String, params: [String: Any], timeout _: Duration) async throws -> Any {
        await Task.yield()
        locked { calls.append((method, params)) }
        guard let response = responses[method] else { throw InviteFailure.connectionClosed }
        return try response.get()
    }

    func close() async {
        await Task.yield()
        locked { isClosed = true }
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// The person's own Mac, answering daemon requests from a table.
@MainActor
final class FakeOwnDaemon: InviteOwnDaemon {
    let responses: [String: Any]
    var methods: [String] = []
    var closed = false
    var supportsCollaborationIdentity = false
    var supportsIdentitySeam = true

    init(responses: [String: Any]) {
        self.responses = responses
    }

    func request(_ method: String, params _: [String: Any]) async throws -> Any {
        await Task.yield()
        methods.append(method)
        guard let response = responses[method] else {
            throw NSError(domain: "test", code: 1, userInfo: [NSError.intentErrorDataCodeKey: "github-not-connected"])
        }
        return response
    }

    func close() {
        closed = true
    }
}

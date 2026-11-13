import Foundation
import Observation

/// What the join needs from the app: the host transport, saved connections,
/// the person's own Mac, and how to save and open the result. Injected so
/// the flow is testable without sockets or persistence.
@MainActor
struct InviteJoinEnvironment {
    var openTransport: (InviteLink) async throws -> any InviteTransport
    var savedConnections: () -> [StoredConnection]
    var openOwnDaemon: (StoredConnection) async throws -> any InviteOwnDaemon
    /// Persists a new credential as an invited session (PairingFlow) and returns its record.
    var saveCredential: (InviteLink, InviteCredential) async throws -> StoredConnection
    /// Routes this window to `connection`, opening `workspaceId` when set.
    var open: (StoredConnection, String?) -> Void
}

/// What the person is asked to confirm before anything is sent to the host.
nonisolated struct InviteJoinConfirmation: Equatable, Sendable {
    enum Method: Equatable, Sendable {
        /// A login this device already holds for the host (`invite.accept`).
        case existingAccess
        /// A proof published by the person's own Mac (`invite.prove`).
        case proveOnMac(macName: String, providerName: String)
    }

    let scope: InviteLink.Scope
    let workspaceTitle: String
    let hostName: String
    let login: String
    let method: Method
}

/// A plain-language reason the join stopped.
nonisolated struct InviteJoinProblem: Equatable, Sendable {
    let title: String
    let message: String
    /// Whether trying again could help (offers Try Again).
    let retryable: Bool
}

/// Drives one `intent://invite` join, mirroring the desktop flow
/// (cloudlands-fe `invite-deep-link.ts`): a returning guest presents the
/// login this device already has for the host; a first-time guest proves a
/// GitHub/GitLab account through their own paired Mac. The result is saved
/// as an invited session (synced to the person's other devices) and opened.
@MainActor
@Observable
final class InviteJoinModel {
    enum Phase: Equatable {
        case connecting
        case confirm(InviteJoinConfirmation)
        case joining
        /// This device has no own Mac to make the identity proof.
        case needsOwnMac
        /// The own Mac has no GitHub/GitLab account signed in for this invite.
        case needsSignIn(providerName: String, macName: String)
        case failed(InviteJoinProblem)
        case finished
    }

    let link: InviteLink
    private(set) var phase: Phase = .connecting
    @ObservationIgnored private let environment: InviteJoinEnvironment
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var decision: CheckedContinuation<Bool, Never>?

    init(link: InviteLink, environment: InviteJoinEnvironment) {
        self.link = link
        self.environment = environment
    }

    /// Starts (or, after a failure, restarts) the join.
    func start() {
        cancel()
        phase = .connecting
        run = Task { [weak self] in await self?.join() }
    }

    /// The person confirmed (true) or declined (false) the prompt.
    func answer(_ confirmed: Bool) {
        decision?.resume(returning: confirmed)
        decision = nil
    }

    func cancel() {
        answer(false)
        run?.cancel()
        run = nil
    }

    // MARK: - Flow

    private func join() async {
        var transport: (any InviteTransport)?
        do {
            let opened = try await environment.openTransport(link)
            transport = opened
            try Task.checkCancellation()
            try await join(over: InviteClient(transport: opened, link: link))
        } catch is CancellationError {
            // Dismissed: nothing to show.
        } catch {
            if !Task.isCancelled { phase = .failed(Self.problem(for: error)) }
        }
        await transport?.close()
    }

    private func join(over client: InviteClient) async throws {
        let preview = try await client.inspect()
        try Task.checkCancellation()
        let saved = environment.savedConnections()
        let sameHost = saved.filter { InvitedSyncKey.sameFingerprint($0.server.certFingerprint, link.fingerprint) }
        if let owned = sameHost.first(where: { $0.principal?.isOwner == true }) {
            // The person owns this host: nothing to join.
            finish(owned, workspaceId: preview.workspaceId)
            return
        }
        let guests = sameHost
            .filter { $0.principal.map { !$0.isOwner } == true && !$0.token.isEmpty }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
        if let first = guests.first {
            let login = first.principal?.login ?? first.displayName
            guard try await confirm(preview: preview, login: login, method: .existingAccess) else { return }
            for guest in guests {
                let joined = try await accept(as: guest, preview: preview, client: client)
                guard !joined else { return }
            }
        }
        try await proveOnOwnMac(preview: preview, client: client, saved: saved)
    }

    /// Returning guest: false when the host no longer knows this login.
    private func accept(as guest: StoredConnection, preview: InvitePreview, client: InviteClient) async throws -> Bool {
        let credential: InviteCredential
        do {
            credential = try await client.accept(credential: guest.token)
        } catch InviteFailure.refused("credential-invalid") {
            return false
        }
        try Task.checkCancellation()
        guard credential.principalId == guest.principal?.id, matches(credential, preview) else {
            throw InviteFailure.invalidResponse
        }
        let connection = credential.token == guest.token ? guest : try await environment.saveCredential(link, credential)
        finish(connection, workspaceId: credential.workspaceId)
        return true
    }

    private func proveOnOwnMac(preview: InvitePreview, client: InviteClient, saved: [StoredConnection]) async throws {
        let macs = saved
            .filter { $0.principal?.isOwner == true && !InvitedSyncKey.sameFingerprint($0.server.certFingerprint, link.fingerprint) }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
        guard let mac = macs.first else {
            phase = .needsOwnMac
            return
        }
        phase = .connecting
        let challenge = try await client.challenge()
        guard challenge.describesSameInvite(as: preview) else { throw InviteFailure.invalidResponse }
        let daemon: any InviteOwnDaemon
        do {
            daemon = try await environment.openOwnDaemon(mac)
        } catch {
            try Task.checkCancellation()
            throw InviteJoinError.ownMacUnreachable(name: mac.displayName)
        }
        defer { daemon.close() }
        try Task.checkCancellation()
        guard let account = try await InviteIdentityProof.account(for: challenge.pin, on: daemon) else {
            phase = .needsSignIn(providerName: Self.requiredProviderName(challenge.pin), macName: mac.displayName)
            return
        }
        let method = InviteJoinConfirmation.Method.proveOnMac(macName: mac.displayName, providerName: account.providerName)
        guard try await confirm(preview: preview, login: account.login, method: method) else { return }
        let session = ProofSession(client: client, daemon: daemon, account: account, preview: preview)
        let (credential, proof) = try await prove(session, challenge: challenge)
        // Point of no return: the host minted the credential. The proof is
        // spent either way, so it is removed before leaving.
        let stored: StoredConnection
        do {
            guard matches(credential, preview),
                  credential.identity == nil || account.identity == nil || credential.identity == account.identity else {
                throw InviteFailure.invalidResponse
            }
            stored = try await environment.saveCredential(link, credential)
        } catch {
            await InviteIdentityProof.delete(proof, collaboration: account.collaboration, on: daemon)
            throw error
        }
        await InviteIdentityProof.delete(proof, collaboration: account.collaboration, on: daemon)
        finish(stored, workspaceId: credential.workspaceId)
    }

    private struct ProofSession {
        let client: InviteClient
        let daemon: any InviteOwnDaemon
        let account: InviteAccount
        let preview: InvitePreview
    }

    /// Publishes the proof and proves it, with one fresh challenge (no new
    /// prompt: consent stands) when the host found the proof stale.
    private func prove(_ session: ProofSession, challenge first: InvitePreview) async throws -> (InviteCredential, InviteProof) {
        let hostLabel = session.preview.hostName ?? link.hosts.first ?? "Intent"
        var challenge = first
        for attempt in 0..<2 {
            guard let nonce = challenge.nonce else { throw InviteFailure.invalidResponse }
            let proof = try await InviteIdentityProof.publish(session.account, nonce: nonce, hostLabel: hostLabel, on: session.daemon)
            do {
                try Task.checkCancellation()
                return (try await session.client.prove(proof, nonce: nonce), proof)
            } catch {
                await InviteIdentityProof.delete(proof, collaboration: session.account.collaboration, on: session.daemon)
                let stale = (error as? InviteFailure)?.refusalCode.map(Self.retryableProofRefusals.contains) == true
                guard stale, attempt == 0 else { throw error }
            }
            challenge = try await session.client.challenge()
            guard challenge.describesSameInvite(as: session.preview) else { throw InviteFailure.invalidResponse }
        }
        throw InviteFailure.refused("proof-expired")
    }

    private static let retryableProofRefusals: Set<String> = ["proof-expired", "proof-invalid"]

    private func matches(_ credential: InviteCredential, _ preview: InvitePreview) -> Bool {
        link.scope == .host || credential.workspaceId == preview.workspaceId
    }

    private func confirm(preview: InvitePreview, login: String, method: InviteJoinConfirmation.Method) async throws -> Bool {
        let confirmation = InviteJoinConfirmation(
            scope: link.scope,
            workspaceTitle: preview.workspaceTitle?.isEmpty == false ? preview.workspaceTitle ?? "" : "Untitled workspace",
            hostName: preview.hostName ?? link.hosts.first ?? "the host",
            login: login,
            method: method
        )
        phase = .confirm(confirmation)
        let confirmed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                decision?.resume(returning: false)
                decision = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answer(false) }
        }
        try Task.checkCancellation()
        guard confirmed else {
            phase = .finished
            return false
        }
        phase = .joining
        return true
    }

    private func finish(_ connection: StoredConnection, workspaceId: String?) {
        phase = .finished
        environment.open(connection, workspaceId)
    }

    private static func requiredProviderName(_ pin: InvitePin) -> String {
        if case .pinned(let identity) = pin { return identity.isGitHub ? "GitHub" : "GitLab" }
        return "GitHub or GitLab"
    }
}

/// Failures the flow raises itself.
nonisolated enum InviteJoinError: Error, Equatable {
    case ownMacUnreachable(name: String)
}

extension InviteJoinModel {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    nonisolated static func problem(for error: any Error) -> InviteJoinProblem {
        let failedTitle = "Couldn't Join"
        let newLink = "Ask the person who shared it for a new link."
        if case .ownMacUnreachable(let name) = error as? InviteJoinError {
            return InviteJoinProblem(
                title: "Couldn't Reach Your Mac",
                message: "Intent couldn't connect to \(name) to confirm your account. Make sure Intent is running on it, then try again.",
                retryable: true
            )
        }
        if let failure = error as? InviteProofFailure {
            return problem(for: failure)
        }
        switch error as? InviteFailure {
        case .refused("invite-not-found"):
            return InviteJoinProblem(title: "Invite Not Found", message: "This invite link isn't valid anymore. \(newLink)", retryable: false)
        case .refused("invite-expired"):
            return InviteJoinProblem(title: "Invite Expired", message: "This invite link has expired. \(newLink)", retryable: false)
        case .refused("invite-revoked"):
            return InviteJoinProblem(title: "Invite Cancelled", message: "The person who shared this workspace cancelled the invite. \(newLink)", retryable: false)
        case .refused("invite-redeemed"):
            return InviteJoinProblem(title: "Invite Already Used", message: "This invite was for one person and has already been used. \(newLink)", retryable: false)
        case .refused("invite-pin-mismatch"):
            return InviteJoinProblem(title: failedTitle, message: "This invite was made for a different GitHub or GitLab account.", retryable: false)
        case .refused("workspace-full"):
            return InviteJoinProblem(title: "Workspace Full", message: "This workspace has no free guest seats. Ask its owner to make room.", retryable: false)
        case .refused("workspace-archived"):
            return InviteJoinProblem(title: failedTitle, message: "This workspace has been archived.", retryable: false)
        case .refused("owner-self-join"):
            return InviteJoinProblem(title: failedTitle, message: "This account owns the host, so it can't join as a guest. Open the host from your saved connections instead.", retryable: false)
        case .refused("github-identity-required"):
            return InviteJoinProblem(title: failedTitle, message: "The host can't accept invites right now: its owner needs to reconnect GitHub or GitLab in Intent.", retryable: true)
        case .refused("github-unreachable"), .refused("identity-unverifiable"):
            return InviteJoinProblem(title: failedTitle, message: "The host couldn't check your account with GitHub or GitLab. Try again in a moment.", retryable: true)
        case .refused("proof-invalid"), .refused("proof-expired"):
            return InviteJoinProblem(title: failedTitle, message: "Your account check didn't go through. Try again.", retryable: true)
        case .refused("invite-flow-busy"):
            return InviteJoinProblem(title: failedTitle, message: "The host is busy. Try again in a moment.", retryable: true)
        case .unreachable, .timedOut:
            return InviteJoinProblem(
                title: "Couldn't Reach the Host",
                message: "Make sure the shared Mac is on and running Intent with Remote Access turned on, then try again.",
                retryable: true
            )
        case .certificateMismatch:
            return InviteJoinProblem(title: failedTitle, message: "The host's security certificate doesn't match this link. \(newLink)", retryable: false)
        case .tunnelUnavailable:
            return InviteJoinProblem(title: failedTitle, message: "This device can't open remote connections. Open the link on your iPhone or Mac.", retryable: false)
        case .connectionClosed:
            return InviteJoinProblem(title: failedTitle, message: "The connection to the host closed. Try again.", retryable: true)
        case .invalidResponse, .refused:
            return InviteJoinProblem(title: failedTitle, message: "The host sent a response this version of Intent doesn't understand. Update Intent and try again.", retryable: false)
        case nil:
            return InviteJoinProblem(title: failedTitle, message: "Something went wrong while joining. Try again.", retryable: true)
        }
    }

    nonisolated private static func problem(for failure: InviteProofFailure) -> InviteJoinProblem {
        let title = "Couldn't Confirm Your Account"
        switch failure {
        case .notSignedIn(let provider):
            let name = provider == "gitlab" ? "GitLab" : "GitHub"
            return InviteJoinProblem(title: title, message: "Sign in to \(name) in Intent on your Mac, then try again.", retryable: true)
        case .wrongAccount(let provider):
            let name = provider == "gitlab" ? "GitLab" : "GitHub"
            return InviteJoinProblem(
                title: title,
                message: "Your Mac is signed in to a different \(name) account than the one this invite was made for.",
                retryable: false
            )
        case .missingScope(let provider):
            let name = provider == "gitlab" ? "GitLab" : "GitHub"
            return InviteJoinProblem(
                title: title,
                message: "Intent on your Mac needs more \(name) permission to confirm your account. Reconnect \(name) there, then try again.",
                retryable: true
            )
        case .rateLimited:
            return InviteJoinProblem(title: title, message: "GitHub or GitLab is limiting requests right now. Try again in a few minutes.", retryable: true)
        case .unsupported:
            return InviteJoinProblem(title: title, message: "Update Intent on your Mac to join with a GitLab account.", retryable: false)
        case .accountChanged:
            return InviteJoinProblem(title: title, message: "The account on your Mac changed while joining. Try again.", retryable: true)
        case .unavailable:
            return InviteJoinProblem(title: title, message: "Your Mac couldn't confirm your account. Try again.", retryable: true)
        }
    }
}

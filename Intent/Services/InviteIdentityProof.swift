import Foundation

/// The person's own daemon (a Mac this phone is paired to as its owner). A
/// first-time guest proves a forge account by having that daemon publish the
/// host's nonce under the account (protocol §5.48 "The identity proof"); the
/// forge token never leaves the Mac. Abstracted for tests.
@MainActor
protocol InviteOwnDaemon: AnyObject {
    /// `collaborationIdentity: 1`: the separate `identity.*` sign-in exists (§5.49).
    var supportsCollaborationIdentity: Bool { get }
    /// Protocol 10.8+ serves GitLab proofs (`sourceControl.identityProof.*`).
    var supportsIdentitySeam: Bool { get }

    func request(_ method: String, params: [String: Any]) async throws -> Any
    func close()
}

/// The forge account the own daemon is signed in as.
nonisolated struct InviteAccount: Equatable, Sendable {
    let provider: String
    let host: String
    let login: String
    /// Known when the account was matched by stable id.
    let externalUserId: String?
    /// Read through the separate collaboration sign-in (`identity.*`).
    let collaboration: Bool

    var isGitHub: Bool { provider == "github" }
    var providerName: String { isGitHub ? "GitHub" : "GitLab" }

    var identity: InviteIdentity? {
        externalUserId.map { InviteIdentity(provider: provider, host: host, externalUserId: $0) }
    }

    func sameAccount(as other: Self) -> Bool {
        provider == other.provider && host == other.host && login == other.login && externalUserId == other.externalUserId
    }
}

/// Why the own daemon could not produce a proof, as bounded reasons.
nonisolated enum InviteProofFailure: Error, Equatable, Sendable {
    /// The Mac published the proof under a different account than the one confirmed.
    case accountChanged
    /// The account lacks the permission a proof needs (`gist` / `api`).
    case missingScope(provider: String)
    /// No account is signed in for the provider the invite needs.
    case notSignedIn(provider: String)
    case rateLimited
    case unavailable
    /// The Mac is too old for the invite's GitLab requirement.
    case unsupported
    /// The signed-in account is not the one the invite was made for.
    case wrongAccount(provider: String)
}

@MainActor
enum InviteIdentityProof {
    /// The account to prove for `pin`, or nil when none is signed in.
    static func account(for pin: InvitePin, on daemon: any InviteOwnDaemon) async throws -> InviteAccount? {
        if daemon.supportsCollaborationIdentity, let account = try await collaborationAccount(for: pin, on: daemon) {
            return account
        }
        let required: InviteIdentity
        switch pin {
        case .pinned(let identity):
            required = identity
        case .unpinned where daemon.supportsIdentitySeam:
            // Explicitly unpinned: the person's selected identity (Settings),
            // or any connected account when none is selected yet.
            guard let selected = try await selectedIdentity(on: daemon) else { return try await anyAccount(on: daemon) }
            required = selected
        case .unknown, .unpinned:
            return try await anyAccount(on: daemon)
        }
        return try await repositoryAccount(matching: required, on: daemon)
    }

    static func publish(
        _ account: InviteAccount,
        nonce: String,
        hostLabel: String,
        on daemon: any InviteOwnDaemon
    ) async throws -> InviteProof {
        var params: [String: Any] = ["nonce": nonce, "hostLabel": hostLabel]
        let method: String
        if account.collaboration, let identity = account.identity {
            method = "sourceControl.identityProof.create"
            params.merge(target(provider: account.provider, host: account.host)) { _, new in new }
            params["purpose"] = "collaboration"
            params["expectedIdentity"] = identity.json
        } else if account.isGitHub {
            method = "github.identityProof.create"
        } else {
            method = "sourceControl.identityProof.create"
            params.merge(target(provider: account.provider, host: account.host)) { _, new in new }
        }
        let result: Any
        do {
            result = try await daemon.request(method, params: params)
        } catch {
            throw failure(error, provider: account.provider)
        }
        let row = result as? [String: Any]
        guard let proofId = (row?["proofId"] as? String) ?? (row?["gistId"] as? String), !proofId.isEmpty,
              let login = row?["login"] as? String, !login.isEmpty else { throw InviteProofFailure.unavailable }
        let proof = InviteProof(provider: account.provider, host: account.host, proofId: proofId, login: login)
        // Never prove an account the person did not confirm.
        guard login == account.login, (row?["provider"] as? String).map({ $0 == account.provider }) ?? true else {
            await delete(proof, collaboration: account.collaboration, on: daemon)
            throw InviteProofFailure.accountChanged
        }
        return proof
    }

    /// Best effort: the proof is spent once the host has read it.
    static func delete(_ proof: InviteProof, collaboration: Bool, on daemon: any InviteOwnDaemon) async {
        var params = target(provider: proof.provider, host: proof.host)
        let method: String
        if collaboration {
            method = "sourceControl.identityProof.delete"
            params["purpose"] = "collaboration"
            params["proofId"] = proof.proofId
        } else if proof.provider == "github" {
            method = "github.identityProof.delete"
            params = ["gistId": proof.proofId]
        } else {
            method = "sourceControl.identityProof.delete"
            params["proofId"] = proof.proofId
        }
        do {
            _ = try await daemon.request(method, params: params)
        } catch {
            AppLog.app.info("[InviteJoin] Could not delete the identity proof")
        }
    }

    // MARK: - Account reads

    private static func collaborationAccount(for pin: InvitePin, on daemon: any InviteOwnDaemon) async throws -> InviteAccount? {
        var wanted: (provider: String, host: String) = ("github", InviteIdentity.githubHost)
        if case .pinned(let identity) = pin {
            wanted = (identity.provider, identity.host)
        } else if let selected = try? await selectedIdentity(on: daemon) {
            wanted = (selected.provider, selected.host)
        }
        let user: [String: Any]
        do {
            let result = try await daemon.request("identity.getUser", params: target(provider: wanted.provider, host: wanted.host))
            user = (result as? [String: Any])?["user"] as? [String: Any] ?? [:]
        } catch {
            if case .rateLimited = failure(error, provider: wanted.provider) { throw InviteProofFailure.rateLimited }
            return nil
        }
        guard let login = nonBlank(user["login"]), let id = stableId(user["id"]) else { return nil }
        if case .pinned(let identity) = pin, identity.externalUserId != id {
            throw InviteProofFailure.wrongAccount(provider: identity.provider)
        }
        return InviteAccount(provider: wanted.provider, host: wanted.host, login: login, externalUserId: id, collaboration: true)
    }

    private static func selectedIdentity(on daemon: any InviteOwnDaemon) async throws -> InviteIdentity? {
        let principal = try await daemon.request("principal.me", params: [:]) as? [String: Any]
        guard let raw = principal?["identity"], !(raw is NSNull) else { return nil }
        guard let identity = InviteIdentity.parse(raw) else { throw InviteProofFailure.unavailable }
        return identity
    }

    /// No requirement (older host): GitHub first, then the Mac's GitLab connection.
    private static func anyAccount(on daemon: any InviteOwnDaemon) async throws -> InviteAccount? {
        let user = try await githubUser(on: daemon)
        if let login = nonBlank(user["login"]) {
            return InviteAccount(provider: "github", host: InviteIdentity.githubHost, login: login, externalUserId: stableId(user["id"]), collaboration: false)
        }
        guard daemon.supportsIdentitySeam else { return nil }
        let status = try await gitlabStatus(params: ["provider": "gitlab"], on: daemon)
        guard status["isConfigured"] as? Bool == true,
              let host = nonBlank(status["host"]),
              let user = status["user"] as? [String: Any], let login = nonBlank(user["login"]) else { return nil }
        return InviteAccount(provider: "gitlab", host: host, login: login, externalUserId: stableId(user["id"]), collaboration: false)
    }

    private static func repositoryAccount(matching required: InviteIdentity, on daemon: any InviteOwnDaemon) async throws -> InviteAccount? {
        if required.isGitHub {
            let user = try await githubUser(on: daemon)
            guard !user.isEmpty else { return nil }
            guard let login = nonBlank(user["login"]), stableId(user["id"]) == required.externalUserId else {
                throw InviteProofFailure.wrongAccount(provider: required.provider)
            }
            return InviteAccount(provider: required.provider, host: required.host, login: login, externalUserId: required.externalUserId, collaboration: false)
        }
        guard daemon.supportsIdentitySeam else { throw InviteProofFailure.unsupported }
        let status = try await gitlabStatus(params: target(provider: required.provider, host: required.host), on: daemon)
        guard status["isConfigured"] as? Bool == true,
              let user = status["user"] as? [String: Any], let login = nonBlank(user["login"]) else { return nil }
        guard status["provider"] as? String == required.provider, status["host"] as? String == required.host,
              stableId(user["id"]) == required.externalUserId else {
            throw InviteProofFailure.wrongAccount(provider: required.provider)
        }
        return InviteAccount(provider: required.provider, host: required.host, login: login, externalUserId: required.externalUserId, collaboration: false)
    }

    /// Empty when GitHub is not connected; a rate limit is neither.
    private static func githubUser(on daemon: any InviteOwnDaemon) async throws -> [String: Any] {
        do {
            let result = try await daemon.request("github.getUser", params: [:])
            return (result as? [String: Any])?["user"] as? [String: Any] ?? [:]
        } catch {
            if case .rateLimited = failure(error, provider: "github") { throw InviteProofFailure.rateLimited }
            return [:]
        }
    }

    /// Empty when the status can't be read; a rate limit throws.
    private static func gitlabStatus(params: [String: Any], on daemon: any InviteOwnDaemon) async throws -> [String: Any] {
        do {
            return try await daemon.request("sourceControl.authStatus", params: params) as? [String: Any] ?? [:]
        } catch {
            if case .rateLimited = failure(error, provider: "gitlab") { throw InviteProofFailure.rateLimited }
            return [:]
        }
    }

    // MARK: - Helpers

    /// GitHub's host param is omitted; other providers name their instance.
    private static func target(provider: String, host: String) -> [String: Any] {
        provider == "github" ? ["provider": provider] : ["provider": provider, "host": host]
    }

    /// The daemon's documented proof refusals (`error.data.code`), else unavailable.
    static func failure(_ error: any Error, provider: String) -> InviteProofFailure {
        if let failure = error as? InviteProofFailure { return failure }
        switch (error as NSError).intentErrorDataCode {
        case "github-not-connected", "gitlab-not-connected": return .notSignedIn(provider: provider)
        case "github-scope-missing", "gitlab-scope-missing": return .missingScope(provider: provider)
        case "rate-limited": return .rateLimited
        case "identity-mismatch": return .wrongAccount(provider: provider)
        default: return .unavailable
        }
    }

    /// The largest integer a JSON number carries exactly (2^53 - 1).
    private static let maximumSafeInteger: Double = 9_007_199_254_740_991

    /// A forge account id as the canonical string (GitHub sends a number).
    static func stableId(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        guard let number = ConnectionPrincipal.number(value), number.isFinite, number >= 0,
              number <= maximumSafeInteger, number.rounded(.down) == number else { return nil }
        return String(Int64(number))
    }

    private static func nonBlank(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

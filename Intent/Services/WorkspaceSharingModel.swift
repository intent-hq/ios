import Foundation
import Observation

/// The Share sheet's state for one workspace: create an invite link
/// (`workspace.invite.create`, protocol §5.48) that anyone can use, or that
/// one GitHub account can use once, and hand it to the system share sheet.
/// People only join by opening a link; members and open links are managed
/// on the Mac.
/// Invite links are capabilities: shown and shared on request, never logged.
@MainActor
@Observable
final class WorkspaceSharingModel {
    typealias Request = @MainActor (String, [String: Any]) async throws -> Any

    /// Who can use the next link.
    enum Audience: Equatable {
        case anyone
        case person
    }

    enum Phase: Equatable {
        case idle
        case creating
        /// The `intent://invite` link the host just created.
        case created(URL)
        case failed(String)
    }

    let workspaceId: String
    /// Protocol 10.8+ hosts take `pinProvider`; without it a host resolves
    /// the login on its own identity's forge, which may be GitLab.
    let namesPinProvider: Bool
    private(set) var phase: Phase = .idle
    var audience: Audience = .anyone
    var pinLogin = ""

    @ObservationIgnored private let request: Request

    init(workspaceId: String, namesPinProvider: Bool, request: @escaping Request) {
        self.workspaceId = workspaceId
        self.namesPinProvider = namesPinProvider
        self.request = request
    }

    nonisolated private static let identitySeamMajor = 10
    nonisolated private static let identitySeamMinor = 8

    /// Whether this host takes `pinProvider` / `pinHost` (protocol 10.8+).
    /// Older hosts only resolve pins on GitHub, so omitting it is the same.
    nonisolated static func namesPinProvider(protocolVersion version: String?) -> Bool {
        let parts = (version ?? "").split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return false }
        return major > identitySeamMajor || (major == identitySeamMajor && minor >= identitySeamMinor)
    }

    var canCreate: Bool {
        phase != .creating && (audience == .anyone || !Self.normalized(pinLogin).isEmpty)
    }

    func createLink() async {
        guard canCreate else { return }
        let login = Self.normalized(pinLogin)
        var params: [String: Any] = ["workspaceId": workspaceId]
        if audience == .person {
            params["pinLogin"] = login
            // The form names a GitHub account; never let the host pick its own forge.
            if namesPinProvider { params["pinProvider"] = "github" }
        }
        phase = .creating
        do {
            let result = try await request("workspace.invite.create", params) as? [String: Any] ?? [:]
            guard let link = Self.inviteURL(from: result) else {
                phase = .failed(SharingFailure.genericMessage)
                return
            }
            phase = .created(link)
        } catch {
            phase = .failed(SharingFailure.message(for: error, pinLogin: audience == .person ? login : nil))
        }
    }

    /// Trims and drops a leading `@`, so `@octo` and `octo` are one account.
    nonisolated static func normalized(_ login: String) -> String {
        let trimmed = login.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }

    /// The result's `url`; only an `intent://` link is shared.
    nonisolated static func inviteURL(from result: [String: Any]) -> URL? {
        guard let text = result["url"] as? String,
              let url = URL(string: text), url.scheme?.lowercased() == "intent" else { return nil }
        return url
    }
}

/// Plain-language messages for invite failures (documented `error.data.code`s).
nonisolated enum SharingFailure {
    static let forbiddenCode = -32_003
    static let genericMessage = "Something went wrong. Try again."

    static func message(for error: any Error, pinLogin: String? = nil) -> String {
        let nsError = error as NSError
        if nsError.code == forbiddenCode { return "Only the workspace owner can invite people." }
        switch nsError.intentErrorDataCode {
        case "listener-down":
            return "Turn on Remote Access in Intent on your Mac before inviting people."
        case "tunnel-down":
            return "Turn on the Tailcat tunnel in Intent on your Mac before inviting people."
        case "github-identity-required":
            return "Connect GitHub or GitLab in Intent on your Mac to create invite links."
        case "github-unreachable":
            return "Your Mac couldn't reach GitHub or GitLab to check its account. Try again in a moment."
        case "guest-limit":
            return "This workspace has reached its guest limit. Remove someone in Intent on your Mac to invite someone else."
        case "invite-pin-unknown":
            return pinLogin.map { "No GitHub user named \($0)." } ?? "That GitHub user doesn't exist."
        case "rate-limited":
            return "GitHub or GitLab is limiting requests right now. Try again in a few minutes."
        default:
            return genericMessage
        }
    }
}

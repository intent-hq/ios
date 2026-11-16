import Foundation
@testable import Intent
import Testing

/// `intent://invite` links (workspace.invite.create) and the `/invite`
/// endpoint's response contracts (protocol §5.48).
struct InviteLinkTests {
    static let fingerprint = String(repeating: "ab", count: 32)
    static let tunnel = "tc1-example"

    static func url(_ query: String, host: String = "invite") throws -> URL {
        try #require(URL(string: "intent://\(host)?\(query)"))
    }

    // MARK: - Link parsing

    @Test func parsesTunnelOnlyLink() throws {
        let link = try #require(InviteLink.parse(try Self.url("v=1&port=5181&fp=\(Self.fingerprint)&inviteId=inv-1&secret=s3cret&tc=\(Self.tunnel)")))
        #expect(link.scope == .workspace)
        #expect(link.hosts.isEmpty)
        #expect(link.port == 5181)
        #expect(link.fingerprint == Self.fingerprint)
        #expect(link.tcAddress == Self.tunnel)
        #expect(link.inviteId == "inv-1")
        #expect(link.secret == "s3cret")
    }

    @Test func parsesLegacyDirectHostsAndHostScope() throws {
        let link = try #require(InviteLink.parse(try Self.url("scope=host&host=10.0.0.5,192.168.1.2&port=5181&fp=\(Self.fingerprint)&inviteId=i&secret=s")))
        #expect(link.scope == .host)
        #expect(link.hosts == ["10.0.0.5", "192.168.1.2"])
        #expect(link.tcAddress == nil)
    }

    @Test func matchesSchemeAndHostCaseInsensitively() throws {
        // ios#406: URI schemes and hosts are case-insensitive.
        let url = try #require(URL(string: "INTENT://Invite?port=5181&fp=\(Self.fingerprint)&inviteId=i&secret=s&tc=\(Self.tunnel)"))
        #expect(InviteLink.isInviteURL(url))
        #expect(InviteLink.parse(url) != nil)
    }

    @Test func rejectsIncompleteOrAmbiguousLinks() throws {
        let base = "port=5181&fp=\(Self.fingerprint)&inviteId=i&secret=s&tc=\(Self.tunnel)"
        let rejected = [
            base.replacingOccurrences(of: "&secret=s", with: ""),
            base.replacingOccurrences(of: "inviteId=i&", with: ""),
            base.replacingOccurrences(of: "port=5181&", with: ""),
            base.replacingOccurrences(of: "port=5181", with: "port=70000"),
            base.replacingOccurrences(of: Self.fingerprint, with: "zz"),
            base.replacingOccurrences(of: "&tc=\(Self.tunnel)", with: ""),
            base + "&secret=other",
            base + "&scope=team",
            base + "&v=2",
            base + "&host=bad/host"
        ]
        for query in rejected {
            #expect(InviteLink.parse(try Self.url(query)) == nil, "\(query)")
        }
        #expect(InviteLink.parse(try Self.url(base, host: "invites")) == nil)
        #expect(InviteLink.parse(try Self.url(base, host: "pair")) == nil)
    }

    @Test func canonicalURLRoundTrips() throws {
        let link = try #require(InviteLink.parse(try Self.url("scope=host&host=10.0.0.5&port=5181&fp=\(Self.fingerprint)&inviteId=i&secret=s&tc=\(Self.tunnel)")))
        let url = try #require(link.url)
        #expect(InviteLink.parse(url) == link)
    }

    @Test func chatLinksToInvitesAreOpenable() throws {
        let url = try Self.url("port=5181&fp=\(Self.fingerprint)&inviteId=i&secret=s&tc=\(Self.tunnel)")
        #expect(UnopenableLink.reason(for: url) == nil)
    }

    // MARK: - /invite responses

    static let workspacePreview: [String: Any] = [
        "workspaceId": "ws-1", "workspaceTitle": "Billing revamp", "hostname": "studio",
        "prettyHostname": "Studio Mac", "collaborationName": NSNull(), "pinIdentity": NSNull()
    ]

    @Test func previewReadsWorkspaceHostNameAndPin() throws {
        let preview = try #require(InvitePreview.parse(Self.workspacePreview, scope: .workspace, requiresNonce: false))
        #expect(preview.workspaceId == "ws-1")
        #expect(preview.workspaceTitle == "Billing revamp")
        #expect(preview.hostName == "Studio Mac")
        #expect(preview.pin == .unpinned)
        var older = Self.workspacePreview
        older.removeValue(forKey: "pinIdentity")
        #expect(InvitePreview.parse(older, scope: .workspace, requiresNonce: false)?.pin == .unknown)
        var pinned = Self.workspacePreview
        pinned["pinIdentity"] = ["provider": "github", "host": "github.com", "externalUserId": "42"]
        #expect(InvitePreview.parse(pinned, scope: .workspace, requiresNonce: false)?.pin
            == .pinned(InviteIdentity(provider: "github", host: "github.com", externalUserId: "42")))
    }

    @Test func previewRejectsMismatchedScopeOrMalformedPin() {
        var malformed = Self.workspacePreview
        malformed["pinIdentity"] = ["provider": "github", "host": "gitlab.com", "externalUserId": "42"]
        #expect(InvitePreview.parse(malformed, scope: .workspace, requiresNonce: false) == nil)
        #expect(InvitePreview.parse(Self.workspacePreview, scope: .host, requiresNonce: false) == nil)
        #expect(InvitePreview.parse(Self.workspacePreview, scope: .workspace, requiresNonce: true) == nil)
        var challenge = Self.workspacePreview
        challenge["nonce"] = "n-1"
        #expect(InvitePreview.parse(challenge, scope: .workspace, requiresNonce: true)?.nonce == "n-1")
    }

    @Test func credentialRequiresTokenAndWorkspace() {
        let valid: [String: Any] = ["status": "authorized", "token": "t", "principalId": "p", "login": "ada", "workspaceId": "ws-1"]
        #expect(InviteCredential.parse(valid, scope: .workspace)?.token == "t")
        for key in ["token", "principalId", "workspaceId"] {
            var missing = valid
            missing.removeValue(forKey: key)
            #expect(InviteCredential.parse(missing, scope: .workspace) == nil, "\(key)")
        }
        var pending = valid
        pending["status"] = "pending"
        #expect(InviteCredential.parse(pending, scope: .workspace) == nil)
    }

    @Test func responsesKeepOnlyDocumentedErrorCodes() throws {
        let refusal = #"{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"secret=abc","data":{"code":"invite-expired"}}}"#
        #expect(throws: InviteFailure.refused("invite-expired")) {
            try InviteSocket.response(to: 3, in: .string(refusal))
        }
        let unknown = #"{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"x","data":{"code":"secret-leak"}}}"#
        #expect(throws: InviteFailure.refused("")) {
            try InviteSocket.response(to: 3, in: .string(unknown))
        }
        let other = #"{"jsonrpc":"2.0","id":2,"result":{}}"#
        #expect(try InviteSocket.response(to: 3, in: .string(other)) == nil)
        let result = #"{"jsonrpc":"2.0","id":3,"result":{"ok":true}}"#
        #expect((try InviteSocket.response(to: 3, in: .string(result)) as? [String: Any])?["ok"] as? Bool == true)
    }

    @Test func proofParamsUseGistIdForGitHub() {
        let github = InviteProof(provider: "github", host: "github.com", proofId: "g1", login: "ada").proveParams(nonce: "n")
        #expect(github["gistId"] as? String == "g1")
        #expect(github["provider"] == nil)
        let gitlab = InviteProof(provider: "gitlab", host: "gitlab.example.com", proofId: "s1", login: "ada").proveParams(nonce: "n")
        #expect(gitlab["proofId"] as? String == "s1")
        #expect(gitlab["host"] as? String == "gitlab.example.com")
    }

    @Test func identityParsingRejectsNonCanonicalHosts() {
        #expect(InviteIdentity.parse(["provider": "gitlab", "host": "gitlab.example.com:8443", "externalUserId": "7"]) != nil)
        #expect(InviteIdentity.parse(["provider": "gitlab", "host": "https://gitlab.com", "externalUserId": "7"]) == nil)
        #expect(InviteIdentity.parse(["provider": "gitlab", "host": "GitLab.com", "externalUserId": "7"]) == nil)
        #expect(InviteIdentity.parse(["provider": "bitbucket", "host": "bitbucket.org", "externalUserId": "7"]) == nil)
    }

    @Test func capabilitiesReadCollaborationIdentityAndSeam() {
        // fixture-protocol-version: brackets the 10.8 identity-proof cutoff
        let hello: [String: Any] = ["server": ["protocolVersion": "10.9", "capabilities": ["collaborationIdentity": 1]]]
        let capabilities = ConnectionCapabilities(hello: hello)
        #expect(capabilities.supportsCollaborationIdentity)
        #expect(capabilities.supportsIdentitySeam)
        // fixture-protocol-version: older than the 10.8 identity-proof cutoff
        let older = ConnectionCapabilities(hello: ["server": ["protocolVersion": "10.7", "capabilities": [:]]])
        #expect(!older.supportsCollaborationIdentity)
        #expect(!older.supportsIdentitySeam)
    }
}

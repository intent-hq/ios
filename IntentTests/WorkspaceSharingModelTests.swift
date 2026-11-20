import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceSharingModelTests {
    final class Host {
        var result: Any = [
            "invite": ["id": "inv-2", "expiresAt": "2026-11-23T10:00:00Z", "reusable": true],
            "url": "intent://invite?inviteId=inv-2",
            "secret": "s"
        ]
        var failure: NSError?
        var calls: [(method: String, params: [String: Any])] = []

        func request(_ method: String, _ params: [String: Any]) async throws -> Any {
            await Task.yield()
            calls.append((method, params))
            if let failure { throw failure }
            return result
        }
    }

    static func model(_ host: Host, namesPinProvider: Bool = true) -> WorkspaceSharingModel {
        WorkspaceSharingModel(workspaceId: "ws-1", namesPinProvider: namesPinProvider) { method, params in
            try await host.request(method, params)
        }
    }

    static func refusal(_ code: String, rpc: Int = -32_602) -> NSError {
        NSError(domain: "test", code: rpc, userInfo: [NSError.intentErrorDataCodeKey: code])
    }

    @Test func createSendsOnlyTheWorkspaceAndShowsTheLink() async {
        let host = Host()
        let model = Self.model(host)
        await model.createLink()
        #expect(host.calls.map(\.method) == ["workspace.invite.create"])
        #expect(host.calls.first?.params.keys.sorted() == ["workspaceId"], "A link anyone can use: no pin")
        #expect(host.calls.first?.params["workspaceId"] as? String == "ws-1")
        guard case .created(let link) = model.phase else {
            Issue.record("Expected a created link, got \(model.phase)")
            return
        }
        #expect(link.url == URL(string: "intent://invite?inviteId=inv-2"))
        #expect(link.expiresAt == WorkspaceSharingModel.date("2026-11-23T10:00:00Z"))
        #expect(link.pinLogin == nil)
    }

    @Test func onePersonLinksPinTheNormalizedLogin() async {
        let host = Host()
        host.result = [
            "invite": ["id": "inv-3", "pinLogin": "grace", "reusable": false],
            "url": "intent://invite?inviteId=inv-3"
        ]
        let model = Self.model(host)
        model.audience = .person
        #expect(!model.canCreate, "A one-person link needs a username")
        model.pinLogin = " @grace "
        await model.createLink()
        #expect(host.calls.first?.params["pinLogin"] as? String == "grace")
        #expect(host.calls.first?.params["pinProvider"] as? String == "github", "A GitLab-identity host must not resolve it on GitLab")
        guard case .created(let link) = model.phase else {
            Issue.record("Expected a created link, got \(model.phase)")
            return
        }
        #expect(link.pinLogin == "grace")
    }

    @Test func expiryReadsInWholeDays() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day: TimeInterval = 86_400
        #expect(WorkspaceSharingModel.expiryText(now.addingTimeInterval(7 * day - 5), now: now) == "Expires in 7 days.")
        #expect(WorkspaceSharingModel.expiryText(now.addingTimeInterval(day + 60), now: now) == "Expires in 2 days.")
        #expect(WorkspaceSharingModel.expiryText(now.addingTimeInterval(day), now: now) == "Expires in 1 day.")
        #expect(WorkspaceSharingModel.expiryText(now.addingTimeInterval(3600), now: now) == "Expires today.")
        #expect(WorkspaceSharingModel.expiryText(now.addingTimeInterval(-1), now: now) == "Expired.")
    }

    @Test func olderHostsGetNoProviderAndVersionsParse() async {
        let host = Host()
        let model = Self.model(host, namesPinProvider: false)
        model.audience = .person
        model.pinLogin = "grace"
        await model.createLink()
        #expect(host.calls.first?.params["pinProvider"] == nil, "Pre-10.8 hosts only know GitHub pins")
        // fixture-protocol-version: pinProvider support starts at protocol 10.8, so the cutoff needs literal versions
        #expect(WorkspaceSharingModel.namesPinProvider(protocolVersion: "18.0"))
        #expect(WorkspaceSharingModel.namesPinProvider(protocolVersion: "10.8")) // fixture-protocol-version: the 10.8 cutoff itself
        #expect(!WorkspaceSharingModel.namesPinProvider(protocolVersion: "10.7")) // fixture-protocol-version: just below the 10.8 cutoff
        #expect(!WorkspaceSharingModel.namesPinProvider(protocolVersion: nil))
    }

    @Test func unknownUsernamesReadPlainly() async {
        let host = Host()
        host.failure = Self.refusal("invite-pin-unknown")
        let model = Self.model(host)
        model.audience = .person
        model.pinLogin = "nobody"
        await model.createLink()
        #expect(model.phase == .failed("No GitHub user named nobody."))
    }

    @Test func onlyIntentLinksAreShared() async {
        let host = Host()
        host.result = ["invite": ["id": "inv-2"], "url": "https://example.com/steal"]
        let model = Self.model(host)
        await model.createLink()
        #expect(model.phase == .failed(SharingFailure.genericMessage))
    }

    @Test func failuresReadPlainlyAndCanBeRetried() async {
        let host = Host()
        let model = Self.model(host)
        host.failure = Self.refusal("tunnel-down", rpc: -32_603)
        await model.createLink()
        #expect(model.phase == .failed("Turn on the Tailcat tunnel in Intent on your Mac before inviting people."))
        host.failure = Self.refusal("github-identity-required")
        await model.createLink()
        #expect(model.phase == .failed("Connect GitHub or GitLab in Intent on your Mac to create invite links."))
        host.failure = Self.refusal("guest-limit")
        await model.createLink()
        guard case .failed(let limit) = model.phase else {
            Issue.record("Expected a failure")
            return
        }
        #expect(limit.contains("guest limit"))
        host.failure = NSError(domain: "test", code: SharingFailure.forbiddenCode)
        await model.createLink()
        #expect(model.phase == .failed("Only the workspace owner can invite people."))
        host.failure = nil
        await model.createLink()
        if case .created = model.phase {} else { Issue.record("Try Again creates a link: \(model.phase)") }
    }
}

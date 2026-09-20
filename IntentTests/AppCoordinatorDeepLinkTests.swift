import Foundation
@testable import Intent
import Testing

extension AppCoordinatorTests {
    @Test func incomingDeepLink_classifiesPairURL() {
        let link = IncomingDeepLink.classify(
            URL(string: "intent://pair?token=t&host=127.0.0.1&port=5181")!
        )
        let expected = PairingPayload(
            hosts: ["127.0.0.1"],
            port: 5181,
            token: "t",
            certFingerprint: nil,
            tcAddress: nil
        )
        #expect(link == .pair(expected))
    }

    @Test func incomingDeepLink_classifiesInviteURLByHostOnly() {
        // The daemon's envelope (pair minus token, plus inviteId/secret).
        let envelope = URL(string:
            "intent://invite?v=1&host=10.0.0.5&port=7443&fp=AB:CD&inviteId=inv-1&secret=s3cret")!
        #expect(IncomingDeepLink.classify(envelope) == .invite)
        // The host alone decides: iOS never parses the invite payload.
        #expect(IncomingDeepLink.classify(URL(string: "intent://invite")!) == .invite)
        #expect(IncomingDeepLink.classify(URL(string: "intent://invite?token=t&host=h&port=1")!) == .invite)
    }

    @Test func incomingDeepLink_classifiesOtherURLsAsUnhandled() {
        #expect(IncomingDeepLink.classify(URL(string: "intent://something?x=1")!) == .unhandled)
        // Missing token — PairingPayload.parse rejects it.
        let malformedPair = URL(string: "intent://pair?host=127.0.0.1&port=5181")!
        #expect(IncomingDeepLink.classify(malformedPair) == .unhandled)
        // Wrong scheme, even with the invite host.
        let wrongScheme = URL(string: "https://invite?inviteId=inv-1")!
        #expect(IncomingDeepLink.classify(wrongScheme) == .unhandled)
    }

    @Test @MainActor func handleIncomingURL_inviteURL_presentsNoticeAndPairsNothing() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        coordinator.onLoadComplete()

        let invite = URL(string:
            "intent://invite?v=1&host=10.0.0.5&port=7443&fp=AB:CD&inviteId=inv-1&secret=s3cret")!
        coordinator.handleIncomingURL(invite)

        #expect(coordinator.isInviteNoticePresented)
        #expect(coordinator.pendingDeepLinkPairing == nil)
        #expect(persistence.loadConnections().isEmpty)
        if case .pairing = coordinator.currentScreen {
            // pass — app state untouched
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func handleIncomingURL_inviteURL_beforeLoadComplete_stashesUntilLoad() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )

        // Cold start: multiple links coalesce into one notice.
        coordinator.handleIncomingURL(URL(string: "intent://invite?inviteId=inv-1&secret=s")!)
        coordinator.handleIncomingURL(URL(string: "intent://invite?inviteId=inv-2&secret=s")!)
        #expect(!coordinator.isInviteNoticePresented)

        coordinator.onLoadComplete()
        #expect(coordinator.isInviteNoticePresented)
        #expect(coordinator.pendingDeepLinkPairing == nil)
        if case .pairing = coordinator.currentScreen {
            // pass — load still routed to its normal first screen
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }

        // The stash is consumed once and must not replay after dismissal.
        coordinator.isInviteNoticePresented = false
        coordinator.onLoadComplete()
        #expect(
            !coordinator.isInviteNoticePresented,
            "A stashed invite notice must not replay after dismissal"
        )
    }
}

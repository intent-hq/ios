import Foundation
@testable import Intent
import Testing

/// `intent://invite` routing: the join sheet, cold-start stashing and where
/// a joined invite lands.
extension AppCoordinatorTests {
    @Test @MainActor func handleIncomingURL_inviteURL_presentsJoinSheetAfterLoad() throws {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        let fingerprint = String(repeating: "ab", count: 32)
        // Cold start: stashed until the first screen is routed.
        coordinator.handleIncomingURL(
            try #require(URL(string: "intent://invite?v=1&port=5181&fp=\(fingerprint)&inviteId=inv-1&secret=s&tc=tc1-x"))
        )
        #expect(coordinator.pendingDeepLink == nil)

        coordinator.onLoadComplete()
        #expect(coordinator.pendingDeepLink?.inviteLink?.inviteId == "inv-1")
        #expect(coordinator.pendingDeepLink?.pairingPayload == nil)
    }

    @Test @MainActor func handleIncomingURL_malformedInviteURL_isIgnored() throws {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        coordinator.onLoadComplete()
        coordinator.handleIncomingURL(try #require(URL(string: "intent://invite?port=5181&inviteId=inv-1")))
        #expect(coordinator.pendingDeepLink == nil)
    }

    @Test @MainActor func onInviteJoined_savesTheWorkspaceToOpenAfterConnecting() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistence.upsertConnection(Self.makeConnection(port: 4243))
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.currentScreen = .workspaceList

        coordinator.onInviteJoined(stored, workspaceId: "ws-shared")

        #expect(coordinator.pendingDeepLink == nil)
        #expect(persistence.loadLastScreen(for: stored.id)?.workspaceId == "ws-shared")
    }
}

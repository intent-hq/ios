import Foundation
@testable import Intent
import Observation
import Security
import Synchronization
import Testing
import UIKit

extension AppCoordinatorTests {
    @Test func retargetRouteReplacesUnboundPairingWindow() {
        #expect(
            WindowRetargetRoute.route(
                currentBackendID: nil,
                target: BackendID(UUID()),
                supportsMultipleWindows: true
            ) == .replaceWindow,
            "An unbound (pairing) window on a multi-window platform is replaced by the target's own window so the scene value is set at creation and stays raisable by openWindow(value:)"
        )
    }

    @Test func retargetRouteRebindsInPlaceOnSingleWindowPlatforms() {
        let current = BackendID(UUID())
        let target = BackendID(UUID())
        #expect(
            WindowRetargetRoute.route(
                currentBackendID: current,
                target: target,
                supportsMultipleWindows: false
            ) == .rebindInPlace,
            "iPhone (single-window) always rebinds the one window in place"
        )
        #expect(WindowRetargetRoute.route(
            currentBackendID: nil,
            target: target,
            supportsMultipleWindows: false
        ) == .rebindInPlace)
    }

    // MARK: - Deep-link URL routing (intent://)

    @Test @MainActor func handleIncomingURL_pairURL_presentsConfirmation() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        coordinator.onLoadComplete()

        coordinator.handleIncomingURL(
            URL(string: "intent://pair?token=t&host=127.0.0.1&port=5181")!
        )

        #expect(coordinator.pendingDeepLinkPairing?.payload == PairingPayload(
            hosts: ["127.0.0.1"],
            port: 5181,
            token: "t",
            certFingerprint: nil,
            tcAddress: nil
        ))
    }

    @Test @MainActor func handleIncomingURL_nonPairURL_isIgnored() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        coordinator.onLoadComplete()

        coordinator.handleIncomingURL(URL(string: "intent://something?x=1")!)

        #expect(coordinator.pendingDeepLinkPairing == nil)
        if case .pairing = coordinator.currentScreen {
            // pass — app state untouched
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func handleIncomingURL_malformedPairURL_isIgnored() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        coordinator.onLoadComplete()

        // Missing token — PairingPayload.parse rejects it.
        coordinator.handleIncomingURL(
            URL(string: "intent://pair?host=127.0.0.1&port=5181")!
        )

        #expect(coordinator.pendingDeepLinkPairing == nil)
        if case .pairing = coordinator.currentScreen {
            // pass — app state untouched
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func handleIncomingURL_beforeLoadComplete_stashesUntilLoad() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )

        // Cold start: the URL arrives while currentScreen is still .loading.
        coordinator.handleIncomingURL(
            URL(string: "intent://pair?token=t&host=10.0.0.5&port=4242")!
        )
        #expect(coordinator.pendingDeepLinkPairing == nil)

        coordinator.onLoadComplete()
        #expect(coordinator.pendingDeepLinkPairing?.payload.hosts == ["10.0.0.5"])
        if case .pairing = coordinator.currentScreen {
            // pass — load still routed to its normal first screen
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onDeepLinkPaired_fromPairingSurface_landsInConnectedUI() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        coordinator.onLoadComplete()
        coordinator.handleIncomingURL(
            URL(string: "intent://pair?token=t&host=127.0.0.1&port=5181")!
        )

        coordinator.onDeepLinkPaired(Self.makeConnection(port: 5181))

        #expect(coordinator.pendingDeepLinkPairing == nil)
        if case .workspaceList = coordinator.currentScreen {
            // pass — same landing as a successful QR scan
        } else {
            Issue.record("Expected .workspaceList, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onDeepLinkPaired_whileConnectedElsewhere_switchesConnection() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.currentScreen = .workspaceList
        coordinator.pendingDeepLinkPairing = DeepLinkPairingRequest(
            payload: PairingPayload(
                hosts: ["10.0.0.1"],
                port: 4242,
                token: "tok-4242",
                certFingerprint: nil,
                tcAddress: nil
            )
        )

        coordinator.onDeepLinkPaired(stored)

        #expect(coordinator.pendingDeepLinkPairing == nil)
        #expect(persistence.activeConnection()?.id == stored.id)
        if case .connecting = coordinator.currentScreen {
            // pass — routed through onSwitchConnection
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
    }
}

extension AppCoordinatorTests {
    @Test @MainActor func onDeepLinkPaired_whileConnecting_restartsConnectionAttempt() {
        resetConnectionState()
        defer { resetConnectionState() }

        // Cold start of a bound window: onLoadComplete routes to .connecting
        // and the stashed deep link is confirmed over it.
        let old = persistence.upsertConnection(Self.makeConnection(port: 1111))
        persistence.setActiveConnection(id: old.id)
        let coordinator = AppCoordinator(
            backendID: BackendID(old.id),
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        coordinator.handleIncomingURL(
            URL(string: "intent://pair?token=t&host=10.0.0.2&port=2222")!
        )
        coordinator.onLoadComplete()
        if case .connecting = coordinator.currentScreen {
            // as expected — the deep-link sheet is presented over .connecting
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
        let attemptBefore = coordinator.connectionAttemptId

        let paired = persistence.upsertConnection(Self.makeConnection(port: 2222))
        coordinator.onDeepLinkPaired(paired)

        // Screen stays .connecting (same value), so the restart must come
        // from the attempt id that keys ConnectingView's .task(id:).
        #expect(coordinator.pendingDeepLinkPairing == nil)
        #expect(persistence.activeConnection()?.id == paired.id)
        #expect(
            coordinator.connectionAttemptId != attemptBefore,
            "Switching while already on .connecting must restart the attempt"
        )
        if case .connecting = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
    }

    // MARK: - Synced backend registry merge

    /// Registry whose keychain returns the given records as raw rows.
    static func syncedRegistry(payloads: [String]) -> SyncedBackendRegistry {
        let rows: [[String: Any]] = payloads.enumerated().map { index, payload in
            [
                kSecAttrAccount as String: "row-\(index)",
                kSecValueData as String: Data(payload.utf8)
            ]
        }
        return SyncedBackendRegistry(
            keychain: FakeSyncedKeychain(outcome: .rows(rows)),
            accessGroup: "T.dev.intentapp.backends"
        )
    }

    static let syncedLivePayload = #"{"v": 1, "label": "Synced Mac", "#
        + #""host": "10.9.9.9", "port": 4242, "fingerprint": "aa:bb", "#
        + #""token": "tok-sync", "updatedAt": 100}"#

    @Test @MainActor func onLoadComplete_mergesRegistryAndOffersSyncedConnections() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [Self.syncedLivePayload])
        )
        coordinator.onLoadComplete()

        let loaded = persistence.loadConnections()
        #expect(loaded.map(\.token) == ["tok-sync"])
        #expect(
            coordinator.pairingShowsSavedConnections,
            "A merged synced connection must be offered on the pairing surface"
        )
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onScenePhaseActive_mergesRegistry() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [Self.syncedLivePayload])
        )
        coordinator.onScenePhaseActive()

        #expect(persistence.loadConnections().count == 1)
    }

    @Test @MainActor func scenePhaseLifecycleBeginsAndEndsBackgroundTask() {
        let identifier = UIBackgroundTaskIdentifier(rawValue: 1)
        var beginCount = 0
        var endedIdentifiers: [UIBackgroundTaskIdentifier] = []
        let backgroundTaskManager = BackgroundTaskManager(
            beginTask: { _ in
                beginCount += 1
                return identifier
            },
            endTask: { endedIdentifiers.append($0) }
        )
        let coordinator = AppCoordinator(
            persistence: persistence,
            backgroundTaskManager: backgroundTaskManager
        )

        coordinator.onScenePhaseNotActive()
        coordinator.onScenePhaseActive()

        #expect(beginCount == 1)
        #expect(endedIdentifiers == [identifier])
    }

    @Test @MainActor func refreshSyncedBackends_onPairingScreen_offersFreshlyMergedConnections() {
        resetConnectionState()
        defer { resetConnectionState() }

        // First-run pairing screen, empty registry: nothing offered.
        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [Self.syncedLivePayload])
        )
        coordinator.currentScreen = .pairing
        #expect(!coordinator.pairingShowsSavedConnections)

        // A foreground merge that adds a synced connection while the pairing
        // surface is up must start offering it.
        coordinator.onScenePhaseActive()
        #expect(
            coordinator.pairingShowsSavedConnections,
            "A merged synced connection must be offered on the already-visible pairing surface"
        )
    }

    @Test @MainActor func refreshSyncedBackends_unavailableRegistryIsANoOp() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let registry = SyncedBackendRegistry(
            keychain: FakeSyncedKeychain(outcome: .failure(errSecNotAvailable)),
            accessGroup: "T.dev.intentapp.backends"
        )
        let coordinator = AppCoordinator(persistence: persistence, syncedRegistry: registry)

        #expect(coordinator.refreshSyncedBackends() == nil)
        #expect(persistence.loadConnections().map(\.id) == [stored.id])
    }

    @Test @MainActor func refreshSyncedBackends_tombstoneOnWindowBackendRoutesToPairing() {
        resetConnectionState()
        defer { resetConnectionState() }

        let doomed = persistence.upsertConnection(
            StoredConnection(
                server: PairedServer(
                    hosts: ["10.9.9.9"],
                    port: 4242,
                    name: "daemon",
                    pairedAt: Date(timeIntervalSince1970: 0),
                    certFingerprint: "aa:bb"
                ),
                token: "tok"
            )
        )
        let other = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: doomed.id)

        // Registry reads use the wall clock, so the tombstone must be recent
        // enough to be within the 30-day TTL and newer than the local pairing.
        let clock = Date().timeIntervalSince1970 * 1000
        let tombstone = #"{"v": 1, "label": "Synced Mac", "#
            + #""host": "10.9.9.9", "port": 4242, "fingerprint": "aa:bb", "#
            + #""updatedAt": \#(clock), "deleted": true}"#
        let coordinator = AppCoordinator(
            backendID: BackendID(doomed.id),
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [tombstone])
        )
        let outcome = coordinator.refreshSyncedBackends()

        #expect(outcome?.removedActiveConnection == true)
        #expect(persistence.loadConnections().map(\.id) == [other.id])
        #expect(persistence.activeConnection() == nil)
        #expect(
            coordinator.pairingShowsSavedConnections,
            "The remaining saved connection must be offered on the pairing surface"
        )
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }
}

extension AppCoordinatorTests {
    @Test @MainActor func refreshSyncedBackends_tombstoneKeepsOtherBackendsLastUsedPointer() {
        resetConnectionState()
        defer { resetConnectionState() }

        let doomed = persistence.upsertConnection(
            StoredConnection(
                server: PairedServer(
                    hosts: ["10.9.9.9"],
                    port: 4242,
                    name: "daemon",
                    pairedAt: Date(timeIntervalSince1970: 0),
                    certFingerprint: "aa:bb"
                ),
                token: "tok"
            )
        )
        let active = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: active.id)

        let clock = Date().timeIntervalSince1970 * 1000
        let tombstone = #"{"v": 1, "label": "Synced Mac", "#
            + #""host": "10.9.9.9", "port": 4242, "fingerprint": "aa:bb", "#
            + #""updatedAt": \#(clock), "deleted": true}"#
        let registry = BackendSessionRegistry()
        let coordinator = AppCoordinator(
            backendID: BackendID(doomed.id),
            persistence: persistence,
            sessionRegistry: registry,
            syncedRegistry: Self.syncedRegistry(payloads: [tombstone])
        )
        let outcome = coordinator.refreshSyncedBackends()

        // The tombstone removed this window's backend — not the last-used
        // one — so this window must still route out.
        #expect(outcome?.removedIds == [doomed.id])
        #expect(outcome?.removedActiveConnection == false)
        #expect(persistence.activeConnection()?.id == active.id)
        #expect(registry.isBackendRemoved(BackendID(doomed.id)))
        if case .pairing = coordinator.currentScreen {
            // pass — exitRemovedBackend ran for the pinned backend's removal
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func refreshSyncedBackends_activeUpdateAdoptsCredentialsIntoConnectionManager() {
        resetConnectionState()
        defer { resetConnectionState() }

        let active = persistence.upsertConnection(
            StoredConnection(
                server: PairedServer(
                    hosts: ["10.9.9.9"],
                    port: 4242,
                    name: "daemon",
                    pairedAt: Date(timeIntervalSince1970: 0),
                    certFingerprint: "aa:bb"
                ),
                token: "tok-old",
                syncUpdatedAt: 100
            )
        )
        persistence.setActiveConnection(id: active.id)

        let rotated = #"{"v": 1, "label": "Synced Mac", "#
            + #""host": "10.9.9.10", "port": 5252, "fingerprint": "aa:bb", "#
            + #""token": "tok-rotated", "updatedAt": 200}"#
        let coordinator = AppCoordinator(
            backendID: BackendID(active.id),
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [rotated])
        )
        let outcome = coordinator.refreshSyncedBackends()

        #expect(outcome?.updatedIds == [active.id])
        let manager = ConnectionManager.shared
        #expect(manager.token == "tok-rotated")
        #expect(manager.port == 5252)
        #expect(manager.hosts.first == "10.9.9.10")
        #expect(manager.certFingerprint == "aa:bb")
    }

    @Test @MainActor func onReconnect_flagsSavedConnections_whenConnectionsExist() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: stored.id)

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onReconnect()

        #expect(
            coordinator.pairingShowsSavedConnections,
            "Pairing surface should offer saved connections after a startup connection failure"
        )
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }
}

import Combine
import Observation
import SwiftUI

/// Owns one window's attachment independently of its native scene value.
/// Home keeps that value (so openWindow can still raise the native window),
/// but releases the backend and displays a fresh, unbound pairing session.
@MainActor
@Observable
final class BackendWindowSession {
    private(set) var session: BackendSession?
    private(set) var isShowingSavedMachines = false
    private let registry: BackendSessionRegistry
    private let persistence: PersistenceManager
    private var savedDisplayName: String?
    let networkAvailability: NetworkAvailability
    @ObservationIgnored private var connectionsObservation: AnyCancellable?
    @ObservationIgnored private var networkLease: NetworkAvailability.Lease?
    @ObservationIgnored private let lifecycleDiagnostics = LifecycleDiagnostics()

    init(
        registry: BackendSessionRegistry = .shared,
        networkAvailability: NetworkAvailability = .shared,
        persistence: PersistenceManager = .shared
    ) {
        self.registry = registry
        self.networkAvailability = networkAvailability
        self.persistence = persistence
        connectionsObservation = persistence.connectionsDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshSceneTitle() }
    }

    /// Attachment identity survives navigation and connection loss. The
    /// native scene value alone cannot distinguish a bound window from Home.
    var sceneTitle: String? {
        guard let backendID = session?.backendID,
              !registry.isBackendRemoved(backendID) else { return nil }
        return savedDisplayName
    }

    private func refreshSceneTitle() {
        guard let backendID = session?.backendID else {
            savedDisplayName = nil
            return
        }
        // A temporarily locked/unavailable Keychain must not erase a known
        // label. A successful read with no matching record does clear it.
        guard let connections = persistence.loadConnectionsWithOutcome().connections else { return }
        savedDisplayName = connections.first { $0.id == backendID.connectionID }?.displayName
    }

    /// Scene-owned, not session-owned: Home, rebinds and retries keep the same lease.
    func updateNetworkObservation(for phase: ScenePhase) {
        if phase == .active { refreshSceneTitle() }
        if phase == .active, networkLease == nil {
            networkLease = networkAvailability.acquire()
        } else if phase == .background {
            stopNetworkObservation()
        }
        #if DEBUG
        NetworkCopyDiagnostics.current?.record(.scene(.init(phase), lease: networkLease != nil))
        #endif
        lifecycleDiagnostics.scene(phase)
    }

    func stopNetworkObservation() {
        lifecycleDiagnostics.stopped()
        networkLease?.cancel()
        networkLease = nil
        #if DEBUG
        NetworkCopyDiagnostics.current?.record(.scene(.stopped, lease: false))
        #endif
    }

    func bind(to backendID: BackendID?) {
        guard session == nil else { return }
        if let backendID, !isShowingSavedMachines {
            session = registry.attach(backendID)
        } else {
            session = registry.makePairingSession()
        }
        refreshSceneTitle()
    }

    func returnToSavedMachines() {
        guard !isShowingSavedMachines else { return }
        release()
        isShowingSavedMachines = true
        bind(to: nil)
    }

    /// Also used for an unchanged scene value: writing the same BackendID
    /// cannot trigger SwiftUI's onChange after returning Home.
    func rebind(to backendID: BackendID?) {
        prepareToRebind()
        bind(to: backendID)
    }

    /// Leaves binding to the root when it must first validate a saved record.
    func prepareToRebind() {
        release()
        isShowingSavedMachines = false
    }

    func release() {
        guard let session else { return }
        self.session = nil
        savedDisplayName = nil
        if let backendID = session.backendID {
            registry.detach(backendID)
        } else {
            session.teardown()
        }
    }
}

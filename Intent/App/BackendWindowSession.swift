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
    let networkAvailability: NetworkAvailability
    @ObservationIgnored private var networkLease: NetworkAvailability.Lease?

    init(registry: BackendSessionRegistry = .shared, networkAvailability: NetworkAvailability = .shared) {
        self.registry = registry
        self.networkAvailability = networkAvailability
    }

    /// Scene-owned, not session-owned: Home, rebinds and retries keep the same lease.
    func updateNetworkObservation(for phase: ScenePhase) {
        if phase == .active, networkLease == nil {
            networkLease = networkAvailability.acquire()
        } else if phase == .background {
            stopNetworkObservation()
        }
        #if DEBUG
        NetworkCopyDiagnostics.current?.record(.scene(.init(phase), lease: networkLease != nil))
        #endif
    }

    func stopNetworkObservation() {
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
        if let backendID = session.backendID {
            registry.detach(backendID)
        } else {
            session.teardown()
        }
    }
}

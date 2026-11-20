import Combine
import Observation
import SwiftUI

@MainActor
@Observable
final class BackendWindowSession {
    private(set) var session: BackendSession?
    private(set) var isShowingSavedMachines = false
    private var hasRestoredSavedMachines = false
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
        guard let connections = persistence.loadConnectionsWithOutcome().connections else { return }
        savedDisplayName = connections.first { $0.id == backendID.connectionID }?.displayName
    }

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

    func restoreSavedMachines(_ restored: Bool, isDemo: Bool = DemoMode.isEnabled) -> Bool {
        guard !hasRestoredSavedMachines else { return isShowingSavedMachines }
        hasRestoredSavedMachines = true
        if restored, !isDemo { returnToSavedMachines() }
        return isShowingSavedMachines
    }

    func prepareForSelection(to target: BackendID, route: WindowRetargetRoute) {
        switch route {
        case .rebindInPlace:
            guard session?.backendID != target else { return }
        case .openTargetWindow, .replaceWindow:
            guard registry.attachmentCount(for: target) == 0 else { return }
        }
        registry.markConnectionSelected(target)
    }

    func rebind(to backendID: BackendID?) {
        prepareToRebind()
        bind(to: backendID)
    }

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

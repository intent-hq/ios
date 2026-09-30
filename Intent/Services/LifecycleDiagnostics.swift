import SwiftUI

@MainActor final class LifecycleDiagnostics {
    private let store: DiagnosticStore
    private let scope: DiagnosticStore.Scope?
    private var lastScene: DiagnosticEvent.Context?

    init(store: DiagnosticStore = .shared) {
        self.store = store
        scope = store.makeScope()
    }

    static func sessionStarted(store: DiagnosticStore = .shared) {
        store.record(DiagnosticEvent(
            kind: .appSessionStarted,
            operation: .appSession,
            site: .appCoordinator,
            stage: .start,
            outcome: .started
        ))
    }

    func scene(_ phase: ScenePhase) {
        switch phase {
        case .active: recordScene(.active)
        case .inactive: recordScene(.inactive)
        case .background: recordScene(.background)
        @unknown default: recordScene(.unknown)
        }
    }

    func stopped() { recordScene(.stopped) }

    private func recordScene(_ context: DiagnosticEvent.Context) {
        guard lastScene != context else { return }
        lastScene = context
        store.record(
            DiagnosticEvent(
                kind: .appSceneChanged,
                operation: .appScene,
                site: .appCoordinator,
                stage: .active,
                outcome: .changed,
                context: context
            ),
            scope: scope
        )
    }
}

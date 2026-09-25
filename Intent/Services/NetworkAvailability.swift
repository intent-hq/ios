import Foundation
import Network
import Observation

/// Presentation-only default-path evidence, independent of socket/retry ownership.
/// Neither a satisfied nor an unsatisfied general path proves endpoint reachability.
@MainActor @Observable
final class NetworkAvailability {
    nonisolated enum Status: Equatable, Sendable {
        case requiresConnection
        case satisfied
        case unknown
        case unsatisfied(NWPath.UnsatisfiedReason?)

        init(_ snapshot: NetworkPathSnapshot) {
            switch snapshot.status {
            case .satisfied: self = .satisfied
            case .unsatisfied: self = .unsatisfied(snapshot.unsatisfiedReason)
            case .requiresConnection: self = .requiresConnection
            @unknown default: self = .unknown
            }
        }
    }

    /// Share across windows, not with ConnectionManager's per-socket monitor.
    static let shared = NetworkAvailability()

    private(set) var status: Status = .unknown
    @ObservationIgnored private let makeMonitor: () -> any NetworkPathMonitoring
    @ObservationIgnored private var monitor: (any NetworkPathMonitoring)?
    @ObservationIgnored private var monitorID: UUID?
    @ObservationIgnored private var observerCount = 0
    @ObservationIgnored private let diagnostics: DiagnosticStore

    init(
        makeMonitor: @escaping () -> any NetworkPathMonitoring = { NWPathMonitorAdapter() },
        diagnostics: DiagnosticStore = .shared
    ) {
        self.makeMonitor = makeMonitor
        self.diagnostics = diagnostics
    }

    /// Retain one lease per foreground scene, including startup and reconnection.
    /// Cancel/release on background or teardown, not on socket replacement or loss.
    /// After the last release, the next acquire awaits a fresh real path callback.
    func acquire() -> Lease {
        Lease(owner: self)
    }

    private func retainObservation() {
        observerCount += 1
        if monitor == nil {
            let identity = UUID()
            let newMonitor = makeMonitor()
            monitorID = identity
            monitor = newMonitor
            newMonitor.start { @MainActor @Sendable [weak self] snapshot in
                #if DEBUG
                NetworkCopyDiagnostics.current?.record(.monitor(
                    Status(snapshot), accepted: self?.monitorID == identity
                ))
                #endif
                guard let self, monitorID == identity else { return }
                let next = Status(snapshot)
                if status != next {
                    status = next
                    recordStatus()
                }
            }
        }
    }

    private func release() {
        observerCount -= 1
        guard observerCount == 0 else { return }
        monitorID = nil
        let retiredMonitor = monitor
        monitor = nil
        if status != .unknown {
            status = .unknown
            recordStatus()
        }
        retiredMonitor?.cancel()
    }

    private func recordStatus() {
        let context: DiagnosticEvent.Context = switch status {
        case .unknown: .unknown
        case .satisfied: .satisfied
        case .requiresConnection: .requiresConnection
        case .unsatisfied(.localNetworkDenied): .localNetworkDenied
        case .unsatisfied: .unsatisfied
        }
        diagnostics.record(DiagnosticEvent(
            kind: .networkAvailabilityChanged,
            operation: .networkAvailability,
            site: .networkAvailability,
            stage: .active,
            outcome: .changed,
            context: context
        ))
    }

    /// Idempotent explicit cancellation, with automatic release at scene teardown.
    @MainActor final class Lease {
        private var owner: NetworkAvailability?

        init(owner: NetworkAvailability) {
            self.owner = owner
            owner.retainObservation()
        }

        isolated deinit {
            owner?.release()
        }

        func cancel() {
            let previousOwner = owner
            owner = nil
            previousOwner?.release()
        }
    }
}

import Foundation
import Observation

/// Presentation only: transport state and the coordinator's recovery/data gate
/// remain authoritative. A background scene cannot pre-present a new failure.
@MainActor
@Observable
final class ConnectionLossPresentation {
    private enum Phase: Equatable {
        case background
        case grace(UUID)
        case immediate
    }

    private var phase = Phase.immediate
    var isDeferred: Bool { phase != .immediate }
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let sleepUntil: (ContinuousClock.Instant) async throws -> Void

    init(
        now: @escaping () -> ContinuousClock.Instant = { .now },
        sleepUntil: @escaping (ContinuousClock.Instant) async throws -> Void = { deadline in
            try await ContinuousClock().sleep(until: deadline)
        }
    ) {
        self.now = now
        self.sleepUntil = sleepUntil
    }

    func enteredBackground(eligible: Bool) {
        deadlineTask?.cancel()
        deadlineTask = nil
        phase = eligible ? .background : .immediate
    }

    func becameActive(onDeadline: @escaping () -> Void) {
        guard phase == .background else { return }
        let generation = UUID()
        let deadline = now() + Constants.AppCoordination.backgroundRecoveryGrace
        let sleepUntil = sleepUntil
        phase = .grace(generation)
        deadlineTask = Task { [weak self] in
            do {
                try await sleepUntil(deadline)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, phase == .grace(generation) else { return }
            // Reconcile a recovery whose publisher delivery is still queued
            // before making any pending loss visible.
            onDeadline()
            reset()
        }
    }

    func recovered() {
        // Recovery while backgrounded still needs protection for a loss queued
        // at reactivation. A real recovery during grace retires the deadline.
        if case .grace = phase { reset() }
    }

    func reset() {
        deadlineTask?.cancel()
        deadlineTask = nil
        phase = .immediate
    }

    isolated deinit {
        deadlineTask?.cancel()
    }
}

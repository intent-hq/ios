import Combine
import Foundation
import UIKit

extension ConnectionManager {
    struct AdmittedHostRace {
        let winner: RacedConnection
        let handshake: ConnectionHandshake
        let drain: Task<[HostCertMismatch], Never>?
    }

    /// Every initial connection and recovery uses this boundary. Racing only
    /// opens a transport; normal subscriptions cannot see a bootstrap seat.
    func readyRace(
        token: String,
        fingerprint: String?,
        race: () async throws -> WonHostRace
    ) async throws -> AdmittedHostRace {
        cancelStartupAdmission()
        let attemptID = startupAdmissionID
        let generation = connectionGeneration
        let credentialsRevision = reconnectCredentialsRevision
        var sawStartup = false
        defer {
            if startupAdmissionID == attemptID {
                let candidate = startupCandidate
                startupCandidate = nil
                Task { await candidate?.disconnect() }
                if Task.isCancelled { startupState = nil }
            }
        }
        while true {
            try checkStartupAttempt(attemptID, generation: generation)
            guard reconnectCredentialsRevision == credentialsRevision else { throw CancellationError() }
            if sawStartup { try await waitForStartupForeground() }
            do {
                let raced = try await race()
                let winner = raced.winner
                do {
                    try checkStartupAttempt(attemptID, generation: generation)
                    startupCandidate = winner
                    let handshake = try await admit(winner, token: token, fingerprint: fingerprint)
                    try checkStartupAttempt(attemptID, generation: generation)
                    guard reconnectCredentialsRevision == credentialsRevision else { throw CancellationError() }
                    startupCandidate = nil
                    startupState = nil
                    return AdmittedHostRace(winner: winner, handshake: handshake, drain: raced.drain)
                } catch {
                    recordLateCertMismatches(from: raced.drain, generation: generation)
                    await winner.disconnect()
                    throw error
                }
            } catch {
                try checkStartupAttempt(attemptID, generation: generation)
                startupCandidate = nil
                if case DaemonStartupError.failed = error { throw error }
                sawStartup = sawStartup || startupState != nil
                guard sawStartup, Self.canRetryStartup(error) else { throw error }
                startupState = .unavailable
                try await Task.sleep(for: .milliseconds(DaemonStartupStatus.minimumRetryMs))
            }
        }
    }

    private static func canRetryStartup(_ error: Error) -> Bool {
        if ConnectionPrincipal.isRevocation(error)
            || (error as? WebSocketTransportError)?.isCertificateMismatch == true
            || error is CancellationError { return false }
        if let admission = error as? ConnectionPrincipal.AdmissionError {
            if case .timedOut = admission { return true }
            return false
        }
        return true
    }

    func receiveStartup(_ state: DaemonStartupState, attemptID: UUID, generation: Int) throws {
        try checkStartupAttempt(attemptID, generation: generation)
        guard !startupSuspended else {
            startupState = .unavailable
            throw DaemonStartupError.reconnect
        }
        // Replacing the entire snapshot also drops counters/ETA when the
        // daemon's attempt ID changes or a future schema is unrecognized.
        startupState = state
    }

    private func checkStartupAttempt(_ id: UUID, generation: Int) throws {
        try Task.checkCancellation()
        guard startupAdmissionID == id, connectionGeneration == generation else { throw CancellationError() }
    }

    func cancelStartupAdmission() {
        startupAdmissionID = UUID()
        let candidate = startupCandidate
        startupCandidate = nil
        startupState = nil
        Task { await candidate?.disconnect() }
        let waiters = startupResumeWaiters.values
        startupResumeWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }

    /// Process lifecycle (not a single iPad window) owns suspension, so one
    /// background scene cannot stop another window's active backend session.
    func observeStartupLifecycle() {
        startupLifecycleObservers = [
            NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
                .sink { [weak self] _ in Task { @MainActor in self?.setStartupSuspended(true) } },
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in Task { @MainActor in self?.setStartupSuspended(false) } }
        ]
    }

    func setStartupSuspended(_ suspended: Bool) {
        startupSuspended = suspended
        if suspended {
            guard startupState != nil else { return }
            startupState = .unavailable
            let candidate = startupCandidate
            Task { await candidate?.disconnect() }
        } else {
            let waiters = startupResumeWaiters.values
            startupResumeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private func waitForStartupForeground() async throws {
        guard startupSuspended else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                startupResumeWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.startupResumeWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }
}

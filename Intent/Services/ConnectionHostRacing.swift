import Foundation
import os

/// The minimal surface `ConnectionManager.raceCandidates` needs from a
/// connection candidate, letting tests race fakes instead of live sockets.
nonisolated protocol HostRacingConnection: Sendable {
    var host: String { get }

    func disconnect() async
}

extension WebSocketConnection: HostRacingConnection {}

/// One raced candidate's live result: the WebSocket plus the tailcat tunnel
/// session carrying it (nil for direct host candidates). `disconnect()` tears
/// down both, so loser cleanup in `raceCandidates` releases tunnel resources
/// when a direct host wins.
nonisolated struct RacedConnection: HostRacingConnection {
    let socket: WebSocketConnection
    let tunnel: (any TunnelSession)?
    /// The candidate label: the direct host, or
    /// `ConnectionManager.tunnelCandidateLabel` for the tunnel route.
    let host: String

    func disconnect() async {
        await socket.disconnect()
        await tunnel?.close()
    }
}

/// The settled result of one `raceCandidates` run: the winner (if any), every
/// per-host certificate mismatch observed before settling, and the failure to
/// throw when no candidate won.
nonisolated struct HostRaceOutcome<Connection: Sendable>: Sendable {
    let winner: Connection?
    let mismatches: [HostCertMismatch]
    let failure: (any Error)?
    /// The background task draining the candidates still in flight when the
    /// race settled: it disconnects every late success (a losing tunnel
    /// session is never leaked) and resolves to the certificate mismatches
    /// those candidates reported. `nil` when every candidate had already
    /// finished.
    let drain: Task<[HostCertMismatch], Never>?
}

/// A single-consumer mailbox for raced candidate results. `raceCandidates`
/// runs its candidates as unstructured tasks — a task group's body cannot
/// return before every child finishes, which is exactly the stall a slow
/// loser would cause — and awaits them here. Unlike `AsyncStream`, delivery
/// keeps working after the consuming task is cancelled, so cleanup can still
/// drain every candidate.
nonisolated private final class RaceMailbox<Connection: Sendable>: Sendable {
    private struct State: Sendable {
        var pending: [Result<Connection, any Error>] = []
        var waiter: CheckedContinuation<Result<Connection, any Error>, Never>?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func deliver(_ result: Result<Connection, any Error>) {
        let waiter = lock.withLock { state -> CheckedContinuation<Result<Connection, any Error>, Never>? in
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.pending.append(result)
            return nil
        }
        waiter?.resume(returning: result)
    }

    func next() async -> Result<Connection, any Error> {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { state -> Result<Connection, any Error>? in
                if state.pending.isEmpty {
                    state.waiter = continuation
                    return nil
                }
                return state.pending.removeFirst()
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

nonisolated private struct HostRaceSettlement<Connection: Sendable>: Sendable {
    let lastError: (any Error)?
    let mismatches: [HostCertMismatch]
    let winner: Connection?
    let cancellationObserved: Bool
    let remaining: Int
}

extension ConnectionManager {
    /// Races one connect attempt per host and settles on the first success
    /// WITHOUT waiting for the losers: the remaining candidates are cancelled
    /// and drained by a background task (see `HostRaceOutcome.drain`) that
    /// disconnects late successes and reports late certificate mismatches, so
    /// a slow loser never delays an already-won connect. Mismatches observed
    /// before settling are collected on the outcome (a loser's mismatch is not
    /// swallowed by the winner). When no candidate succeeds, every candidate
    /// is awaited and `failure` prefers an aggregate certificate error over
    /// generic failures. Cancelling the losers runs each candidate's task
    /// cancellation handlers synchronously on the settling thread, so
    /// candidate cancellation handlers must not block (the tunnel dial's
    /// `DialHandle.cancel()` closes off-thread for this reason) — a blocking
    /// handler would stall the settle inside `cancelAll()`. Generic over the
    /// connection so tests can race fakes; internal for test visibility.
    nonisolated static func raceCandidates<Connection: HostRacingConnection>(
        _ hosts: [String],
        diagnostics: DiagnosticStore = .shared,
        connect: @escaping @Sendable (String) async throws -> Connection
    ) async -> HostRaceOutcome<Connection> {
        let mailbox = RaceMailbox<Connection>()
        let candidates = startCandidates(hosts, connect: connect, mailbox: mailbox)
        let cancelAll = { @Sendable in cancelCandidates(candidates) }

        return await withTaskCancellationHandler {
            let settlement = await settleCandidates(
                count: hosts.count,
                candidates: candidates,
                mailbox: mailbox,
                diagnostics: diagnostics
            )
            let drain = makeDrain(
                remaining: settlement.remaining,
                mailbox: mailbox,
                diagnostics: diagnostics,
                hasWinner: settlement.winner != nil
            )
            return await makeOutcome(settlement: settlement, hosts: hosts, drain: drain)
        } onCancel: {
            cancelAll()
        }
    }

    nonisolated private static func startCandidates<Connection: HostRacingConnection>(
        _ hosts: [String],
        connect: @escaping @Sendable (String) async throws -> Connection,
        mailbox: RaceMailbox<Connection>
    ) -> [Task<Void, Never>] {
        hosts.map { host in
            Task {
                do {
                    let connection = try await connect(host)
                    mailbox.deliver(.success(connection))
                } catch {
                    mailbox.deliver(.failure(error))
                }
            }
        }
    }

    nonisolated private static func cancelCandidates(_ candidates: [Task<Void, Never>]) {
        for candidate in candidates {
            candidate.cancel()
        }
    }

    nonisolated private static func settleCandidates<Connection: HostRacingConnection>(
        count: Int,
        candidates: [Task<Void, Never>],
        mailbox: RaceMailbox<Connection>,
        diagnostics: DiagnosticStore
    ) async -> HostRaceSettlement<Connection> {
        var lastError: Error?
        var mismatches: [HostCertMismatch] = []
        var winner: Connection?
        var cancellationObserved = false
        var remaining = count
        settle: while remaining > 0 {
            let result = await mailbox.next()
            remaining -= 1
            switch result {
            case .success(let connection):
                cancelCandidates(candidates)
                if Task.isCancelled {
                    cancellationObserved = true
                    await connection.disconnect()
                    break settle
                }
                winner = connection
                break settle
            case .failure(let error):
                if !Task.isCancelled, !(error is CancellationError) {
                    let failure = TransportDiagnosticFailure.classify(error)
                    diagnostics.record(DiagnosticEvent(
                        kind: failure.classification == .pinMismatch || failure.classification == .noCertificate
                            ? .trustRejected : .connectionAttempt,
                        operation: failure.classification == .pinMismatch || failure.classification == .noCertificate
                            ? .trustReject : .connectionAttempt,
                        site: .webSocket,
                        stage: .connect,
                        outcome: .fallbackPending,
                        failure: failure,
                        effect: .candidateRejected
                    ))
                }
                if Task.isCancelled {
                    cancellationObserved = true
                    cancelCandidates(candidates)
                }
                lastError = error
                appendMismatch(from: error, to: &mismatches)
                AppLog.connection.debug("[ConnectionManager] Host racing: \(error.localizedDescription)")
                if cancellationObserved { break settle }
            }
        }
        return HostRaceSettlement(
            lastError: lastError,
            mismatches: mismatches,
            winner: winner,
            cancellationObserved: cancellationObserved,
            remaining: remaining
        )
    }

    nonisolated private static func appendMismatch(
        from error: Error,
        to mismatches: inout [HostCertMismatch]
    ) {
        if let transportError = error as? WebSocketTransportError,
           case let .certificateMismatch(host, fingerprint) = transportError {
            mismatches.append(HostCertMismatch(host: host, fingerprint: fingerprint))
        }
    }

    nonisolated private static func makeDrain<Connection: HostRacingConnection>(
        remaining: Int,
        mailbox: RaceMailbox<Connection>,
        diagnostics: DiagnosticStore,
        hasWinner: Bool
    ) -> Task<[HostCertMismatch], Never>? {
        guard remaining > 0 else { return nil }
        AppLog.connection.debug("[ConnectionManager] Host racing settled; draining \(remaining) candidate(s) in the background")
        return Task.detached {
            var lateMismatches: [HostCertMismatch] = []
            for _ in 0..<remaining {
                switch await mailbox.next() {
                case .success(let loser):
                    await loser.disconnect()
                case .failure(let error):
                    appendMismatch(from: error, to: &lateMismatches)
                    // Losing candidates are cancelled deliberately. A concrete
                    // late pin rejection still matters; generic cancellation
                    // fallout does not represent another connection failure.
                    if hasWinner, let error = error as? WebSocketTransportError, error.isCertificateMismatch {
                        diagnostics.record(DiagnosticEvent(
                            kind: .trustRejected,
                            operation: .trustReject,
                            site: .webSocket,
                            stage: .connect,
                            outcome: .recovered,
                            failure: TransportDiagnosticFailure.classify(error),
                            effect: .candidateRejected
                        ))
                    }
                    AppLog.connection.debug("[ConnectionManager] Host racing: \(error.localizedDescription)")
                }
            }
            return lateMismatches
        }
    }

    nonisolated private static func makeOutcome<Connection: HostRacingConnection>(
        settlement: HostRaceSettlement<Connection>,
        hosts: [String],
        drain: Task<[HostCertMismatch], Never>?
    ) async -> HostRaceOutcome<Connection> {
        if settlement.cancellationObserved || Task.isCancelled {
            if let winner = settlement.winner {
                await winner.disconnect()
            }
            return HostRaceOutcome(
                winner: nil,
                mismatches: settlement.mismatches,
                failure: CancellationError(),
                drain: drain
            )
        }
        if let winner = settlement.winner {
            return HostRaceOutcome(
                winner: winner,
                mismatches: settlement.mismatches,
                failure: nil,
                drain: drain
            )
        }
        if !settlement.mismatches.isEmpty {
            return HostRaceOutcome(
                winner: nil,
                mismatches: settlement.mismatches,
                failure: WebSocketTransportError.certificateMismatches(
                    mismatches: settlement.mismatches
                ),
                drain: drain
            )
        }
        return HostRaceOutcome(
            winner: nil,
            mismatches: settlement.mismatches,
            failure: settlement.lastError ?? WebSocketTransportError.failed(
                host: hosts.first ?? "unknown",
                message: "No reachable host found"
            ),
            drain: drain
        )
    }
}

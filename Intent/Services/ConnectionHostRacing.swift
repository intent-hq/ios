import Foundation
import os

nonisolated protocol HostRacingConnection: Sendable {
    var host: String { get }

    func disconnect() async
}

extension WebSocketConnection: HostRacingConnection {}

nonisolated struct RacedConnection: HostRacingConnection {
    let socket: WebSocketConnection
    let tunnel: (any TunnelSession)?
    let host: String

    func disconnect() async {
        await socket.disconnect()
        await tunnel?.close()
    }
}

nonisolated struct HostRaceOutcome<Connection: Sendable>: Sendable {
    let winner: Connection?
    let mismatches: [HostCertMismatch]
    let failure: (any Error)?
    let drain: Task<[HostCertMismatch], Never>?
}

nonisolated struct TunnelEstablishmentFailure: Error {
    let underlyingError: any Error
}

nonisolated private struct HostRaceCandidateFailure: Error {
    let underlyingError: any Error
    let context: DiagnosticEvent.Context
    let stage: DiagnosticEvent.Stage

    init(host: String, error: any Error) {
        let establishment = error as? TunnelEstablishmentFailure
        underlyingError = establishment?.underlyingError ?? error
        let isTunnel = host == ConnectionManager.tunnelCandidateLabel
        context = isTunnel ? .tunnel : .lan
        stage = isTunnel ? (establishment == nil ? .tunnelHandshake : .tunnelEstablish) : .connect
    }

    func diagnosticEvent(outcome: DiagnosticEvent.Outcome) -> DiagnosticEvent {
        let failure = TransportDiagnosticFailure.classify(underlyingError)
        let trustRejected = failure.classification == .pinMismatch || failure.classification == .noCertificate
        return DiagnosticEvent(
            kind: trustRejected ? .trustRejected : .connectionAttempt,
            operation: trustRejected ? .trustReject : .connectionAttempt,
            site: .webSocket,
            stage: stage,
            outcome: outcome,
            failure: failure,
            effect: .candidateRejected,
            context: context
        )
    }
}

nonisolated private final class RaceMailbox<Connection: Sendable>: Sendable {
    typealias CandidateResult = Result<Connection, HostRaceCandidateFailure>

    private struct State: Sendable {
        var pending: [CandidateResult] = []
        var waiter: CheckedContinuation<CandidateResult, Never>?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func deliver(_ result: CandidateResult) {
        let waiter = lock.withLock { state -> CheckedContinuation<CandidateResult, Never>? in
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.pending.append(result)
            return nil
        }
        waiter?.resume(returning: result)
    }

    func next() async -> CandidateResult {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { state -> CandidateResult? in
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
                    mailbox.deliver(.failure(HostRaceCandidateFailure(host: host, error: error)))
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
            case .failure(let candidate):
                let error = candidate.underlyingError
                if !Task.isCancelled, !(error is CancellationError) {
                    diagnostics.record(candidate.diagnosticEvent(outcome: .fallbackPending))
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
                case .failure(let candidate):
                    let error = candidate.underlyingError
                    appendMismatch(from: error, to: &lateMismatches)
                    if hasWinner, let error = error as? WebSocketTransportError, error.isCertificateMismatch {
                        diagnostics.record(candidate.diagnosticEvent(outcome: .recovered))
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

import Foundation
@testable import Intent
import Network
import os
import Testing

/// Exercises real producer paths without the DEBUG-only plaintext socket escape.
@MainActor struct TransportDiagnosticTests {
    private let marker = "synthetic-private-host-token-path"

    @Test func requestOriginSurvivesFlatteningAndIsRecordedExactlyOnce() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let manager = ConnectionManager(diagnostics: store)
        let owner = DiagnosticRequestContext.Owner(operation: .workspaceLoad, site: .workspaceStore)
        do {
            _ = try await DiagnosticRequestContext.$owner.withValue(owner) {
                try await manager.awaitResponse(id: 1, timeout: 10) {
                    manager.handleTextMessage("""
                    {"id":1,"error":{"code":-2,"message":"\(marker)","data":{"code":"\(marker)"}}}
                    """)
                    return nil
                }
            }
            Issue.record("Expected remote rejection")
        } catch {
            let failure = DiagnosticErrorOwnership.failure(for: error)
            #expect(failure.origin == .remoteRPC)
            #expect(failure.classification == .remoteRejected)
            #expect(failure.code == .other)
            #expect((error as NSError).isEntityNotFound == false)
            #expect(!DiagnosticErrorOwnership.record(error, event: DiagnosticFixtures.event(), store: store))
        }
        let snapshot = await store.snapshot()
        let records = try DiagnosticFixtures.records(snapshot)
        #expect(records.count == 1)
        #expect(records.first?.event.operation == .workspaceLoad)
        #expect(records.first?.event.effect == .remoteRejected)
        #expect(try #require(String(data: snapshot.jsonLines, encoding: .utf8)).contains(marker) == false)
        let report = try #require(await store.beginReport())
        let entries = try DiagnosticZIPTestReader.extract(Data(contentsOf: report.archiveURL))
        let persisted = try #require(entries["events.jsonl"])
        #expect(persisted == report.snapshot.jsonLines)
        #expect(try #require(String(data: persisted, encoding: .utf8)).contains(marker) == false)
        #expect(await store.endReport(report))
    }

    @Test func localTimeoutAndNotConnectedDoNotMasqueradeAsRemoteErrors() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let manager = ConnectionManager(diagnostics: store)
        do { _ = try await manager.awaitResponse(id: 1, timeout: 0) { nil } } catch {}
        do { _ = try await manager.request(marker, params: [marker: marker]) } catch {}
        let records = try DiagnosticFixtures.records(await store.snapshot())
        #expect(records.map(\.event.failure.classification) == [.requestTimeout, .notConnected])
        #expect(records.allSatisfy { $0.event.failure.origin == .localRequest })
        #expect(records.map(\.event.effect) == [.unknown, .notSent])
    }

    @Test func cancellationAndDisconnectPropagationAreBenign() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let manager = ConnectionManager(diagnostics: store)
        let task = Task { _ = try await manager.awaitResponse(id: 1, timeout: 10) { nil } }
        task.cancel()
        do { _ = try await task.value } catch {}
        do {
            _ = try await manager.awaitResponse(id: 2, timeout: 10) {
                manager.failAllPending(error: marker)
                return nil
            }
        } catch {
            #expect(!DiagnosticErrorOwnership.record(error, event: DiagnosticFixtures.event(), store: store))
        }
        #expect(try DiagnosticFixtures.records(await store.snapshot()).isEmpty)
        #expect(manager.pendingRequests.isEmpty)
    }

    @Test func malformedProtocolEventsExcludePayloadsAndIgnorePartialFrames() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let manager = ConnectionManager(diagnostics: store)
        manager.handleTextMessage(marker)
        manager.handleTextMessage(marker)
        manager.handleTextMessage("""
        {"method":"subscription.push","params":{"subscriptionId":"\(marker)"}}
        """)
        var assembler = WebSocketConnection.MessageAssembler(diagnostics: store)
        _ = try assembler.consume(kind: .text, data: Data(marker.utf8), isComplete: false)
        _ = try assembler.consume(kind: .continuation, data: Data(), isComplete: true)
        _ = try assembler.consume(kind: .continuation, data: Data(marker.utf8), isComplete: true)
        #expect(throws: WebSocketConnection.MessageAssemblyError.self) {
            _ = try assembler.consume(kind: .text, data: Data([0xFF]), isComplete: true)
        }
        let snapshot = await store.snapshot()
        let records = try DiagnosticFixtures.records(snapshot)
        #expect(records.map(\.event.operation) == [.protocolInboundJSON, .protocolSubscriptionPush, .protocolMessageAssembly])
        #expect(records.map(\.count) == [2, 1, 2])
        #expect(try #require(String(data: snapshot.jsonLines, encoding: .utf8)).contains(marker) == false)
    }

    @Test func missingPinProducesStartAndTerminalAttemptWithoutDialing() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let manager = ConnectionManager(diagnostics: store)
        do {
            try await DiagnosticConnectContext.$origin.withValue(.pairing) {
                try await manager.connect(hosts: [marker], port: 4242, token: marker)
            }
            Issue.record("Expected missing pin")
        } catch {}
        let records = try DiagnosticFixtures.records(await store.snapshot())
        #expect(records.map(\.event.outcome) == [.started, .failed])
        #expect(records.last?.event.failure.classification == .missingPin)
        #expect(records.allSatisfy { $0.event.context == .pairing })
        #expect(records.first?.scope == records.last?.scope)
        #expect(manager.connectionState == .disconnected)
    }

    @Test func connectionLossIsRecordedOnceBeforeIntentionalTeardown() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let manager = ConnectionManager(diagnostics: store)
        manager.connectionState = .connected
        manager.handleDisconnection(cause: .heartbeatFailure)
        manager.handleDisconnection(cause: .heartbeatFailure)
        manager.disconnect()
        manager.disconnect()
        let records = try DiagnosticFixtures.records(await store.snapshot())
        #expect(records.map(\.event.context) == [.heartbeatFailure, .explicitDisconnect])
        #expect(records.map(\.count) == [1, 1])
    }

    @Test func trustCandidateFailuresAreSafeAndCancellationIsNotAFailure() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let outcome: HostRaceOutcome<DiagnosticRaceConnection> = await ConnectionManager.raceCandidates([marker], diagnostics: store) { host in
            throw WebSocketTransportError.certificateMismatch(host: host, fingerprint: host)
        }
        #expect(outcome.winner == nil)
        #expect(outcome.mismatches.count == 1)
        let cancelled: HostRaceOutcome<DiagnosticRaceConnection> = await ConnectionManager.raceCandidates([marker], diagnostics: store) { _ in
            throw CancellationError()
        }
        #expect(cancelled.winner == nil)
        let snapshot = await store.snapshot()
        let records = try DiagnosticFixtures.records(snapshot)
        #expect(records.count == 1)
        #expect(records.first?.event.kind == .trustRejected)
        #expect(records.first?.event.effect == .candidateRejected)
        #expect(records.first?.event.context == .lan)
        #expect(records.first?.event.stage == .connect)
        #expect(try #require(String(data: snapshot.jsonLines, encoding: .utf8)).contains(marker) == false)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func lateTrustFailureSurvivesSuccessfulRaceWithoutDelayingWinner(tunnel: Bool) async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let release = TestGate()
        let loser = tunnel ? ConnectionManager.tunnelCandidateLabel : "private-loser"
        let outcome: HostRaceOutcome<DiagnosticRaceConnection> = await release.opening {
            await ConnectionManager.raceCandidates(["private-winner", loser], diagnostics: store) { host in
                if host == loser {
                    await release.wait()
                    throw WebSocketTransportError.certificateMismatch(host: host, fingerprint: host)
                }
                return DiagnosticRaceConnection(host: host)
            }
        }
        #expect(outcome.winner != nil)
        release.open()
        #expect(await outcome.drain?.value.count == 1)
        let snapshot = await store.snapshot()
        let records = try DiagnosticFixtures.records(snapshot)
        #expect(records.count == 1)
        #expect(records.first?.event.outcome == .recovered)
        #expect(records.first?.event.failure.classification == .pinMismatch)
        #expect(records.first?.event.context == (tunnel ? .tunnel : .lan))
        #expect(records.first?.event.stage == (tunnel ? .tunnelHandshake : .connect))
        #expect(try #require(String(data: snapshot.jsonLines, encoding: .utf8)).contains("private-") == false)
    }

    @Test func foreignErrorTextAndDomainCannotForgeLocalClassification() {
        let foreign = NSError(domain: "WebSocket", code: -2, userInfo: [NSLocalizedDescriptionKey: marker])
        #expect(DiagnosticErrorOwnership.failure(for: foreign).origin == .unknown)
        #expect(TransportDiagnosticFailure.classify(NWError.posix(.ECONNREFUSED)).code == .connectionRefused)
        #expect(TransportDiagnosticFailure.classify(WebSocketTransportError.disconnected(host: marker, code: 4999, reason: marker)).code == .other)
    }

    @Test func deferredOwnerCanClassifyRecoveryWithoutADuplicateTransportFailure() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let manager = ConnectionManager(diagnostics: store)
        let owner = DiagnosticRequestContext.Owner(operation: .workspaceLoad, site: .workspaceStore, recording: .deferred)
        do {
            _ = try await DiagnosticRequestContext.$owner.withValue(owner) {
                try await manager.request(marker)
            }
        } catch {
            #expect(try DiagnosticFixtures.records(await store.snapshot()).isEmpty)
            let event = DiagnosticFixtures.event(outcome: .recovered, failure: DiagnosticErrorOwnership.failure(for: error))
            #expect(DiagnosticErrorOwnership.record(error, event: event, store: store))
            #expect(!DiagnosticErrorOwnership.record(error, event: event, store: store))
        }
        let records = try DiagnosticFixtures.records(await store.snapshot())
        #expect(records.count == 1)
        #expect(records.first?.event.outcome == .recovered)
    }
}

nonisolated private struct DiagnosticRaceConnection: HostRacingConnection {
    let host: String

    func disconnect() async {}
}

extension ConnectionManagerTests {
    nonisolated enum CandidateFailureCase: CaseIterable {
        case lan, tunnelEstablish, tunnelHandshake
    }

    @Test func cancelledTunnelEstablishmentPreservesCancellationWithoutDiagnosticFailure() async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let outcome = await ConnectionManager.raceCandidates([ConnectionManager.tunnelCandidateLabel], diagnostics: store) { _ in
            try await ConnectionManager.connectViaTunnel(
                dialer: CancellingTunnelDialer(),
                tcAddress: "synthetic-private-address",
                remotePort: 5181,
                token: "synthetic-private-token",
                certFingerprint: "aa:bb"
            )
        }
        #expect(outcome.failure is CancellationError)
        #expect(try DiagnosticFixtures.records(await store.snapshot()).isEmpty)
    }

    nonisolated private struct CancellingTunnelDialer: TunnelDialing {
        func open(tcAddress _: String, remotePort _: Int) async throws -> any TunnelSession {
            throw CancellationError()
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: CandidateFailureCase.allCases)
    func rejectedCandidateRecordsRouteAndStage(scenario: CandidateFailureCase) async throws {
        let store = DiagnosticStore(storage: DiagnosticTestStorage())
        let accepted = OSAllocatedUnfairLock(initialState: [NWConnection]())
        let listener = scenario == .tunnelHandshake ? try await Self.startSilentListener(accepted: accepted) : nil
        defer {
            listener?.cancel()
            accepted.withLock { $0.forEach { $0.cancel() } }
        }
        let tunnel = FakeTunnelSession(localPort: Int(listener?.port?.rawValue ?? 1))
        let marker = "synthetic-private-candidate"
        let dialer = FakeTunnelDialer(result: scenario == .tunnelEstablish
            ? .failure(.failed(host: marker, message: marker)) : .success(tunnel))
        let candidate = scenario == .lan ? marker : ConnectionManager.tunnelCandidateLabel
        let outcome = await ConnectionManager.raceCandidates([candidate], diagnostics: store) { _ -> RacedConnection in
            if scenario == .lan { throw NWError.posix(.ECONNREFUSED) }
            return try await ConnectionManager.connectViaTunnel(
                dialer: dialer,
                tcAddress: marker,
                remotePort: 5181,
                token: marker,
                certFingerprint: "aa:bb"
            )
        }
        #expect(outcome.winner == nil)
        #expect(outcome.failure != nil)
        let snapshot = await store.snapshot()
        let records = try DiagnosticFixtures.records(snapshot)
        #expect(records.count == 1)
        let event = try #require(records.first?.event)
        #expect(event.effect == .candidateRejected)
        #expect(event.outcome == .fallbackPending)
        switch scenario {
        case .lan:
            #expect(event.context.rawValue == "lan")
            #expect(event.stage.rawValue == "connect")
            #expect(event.failure.code == .connectionRefused)
        case .tunnelEstablish:
            #expect(event.context.rawValue == "tunnel")
            #expect(event.stage.rawValue == "tunnel_establish")
        case .tunnelHandshake:
            #expect(event.context.rawValue == "tunnel")
            #expect(event.stage.rawValue == "tunnel_handshake")
            #expect(event.failure.classification == .requestTimeout)
            #expect(tunnel.isClosed)
        }
        let json = try #require(String(data: DiagnosticEncoding.encoder().encode(event), encoding: .utf8))
        for privateValue in [marker, "127.0.0.1", "5181", "aa:bb"] {
            #expect(!json.contains(privateValue))
        }
    }

    /// Accepts TCP but sends no TLS/WSS response, exercising the real handshake
    /// deadline without changing production timeouts or injecting a fake socket.
    nonisolated private static func startSilentListener(
        accepted: OSAllocatedUnfairLock<[NWConnection]>
    ) async throws -> NWListener {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "ConnectionManagerHostRaceTests.silent-listener")
        listener.newConnectionHandler = { @Sendable connection in
            accepted.withLock { $0.append(connection) }
            connection.start(queue: queue)
        }
        let (ready, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
        listener.stateUpdateHandler = { @Sendable state in
            switch state {
            case .ready:
                continuation.yield(())
                continuation.finish()
            case .failed(let error): continuation.finish(throwing: error)
            case .cancelled: continuation.finish(throwing: CancellationError())
            default: break
            }
        }
        listener.start(queue: queue)
        do {
            for try await _ in ready { break }
            return listener
        } catch {
            listener.cancel()
            throw error
        }
    }
}

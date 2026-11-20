import Foundation
import Network
import os

enum CertFingerprintProbe {
    enum Outcome: Equatable {
        case abort(message: String)
        case confirmFingerprint(String)
    }

    nonisolated enum FailureDomain: String, Sendable {
        case dns = "DNS"
        case network = "Network"
        case posix = "POSIX"
        case tls = "TLS"
    }

    nonisolated struct FailureCause: Equatable, Sendable, CustomStringConvertible {
        let domain: FailureDomain
        let code: Int32

        init(domain: FailureDomain, code: Int32) {
            self.domain = domain
            self.code = code
        }

        init(_ error: NWError) {
            switch error {
            case .posix(let code): self.init(domain: .posix, code: code.rawValue)
            case .dns(let code): self.init(domain: .dns, code: code)
            case .tls(let status): self.init(domain: .tls, code: status)
            case .wifiAware(let code): self.init(domain: .network, code: code)
            @unknown default: self.init(domain: .network, code: 0)
            }
        }

        var label: String? {
            switch (domain, code) {
            case (.posix, POSIXErrorCode.ECONNREFUSED.rawValue): "connection refused"
            case (.posix, POSIXErrorCode.ECONNRESET.rawValue): "connection reset"
            case (.posix, POSIXErrorCode.EHOSTUNREACH.rawValue): "host unreachable"
            case (.posix, POSIXErrorCode.EHOSTDOWN.rawValue): "host down"
            case (.posix, POSIXErrorCode.ENETUNREACH.rawValue): "network unreachable"
            case (.posix, POSIXErrorCode.ENETDOWN.rawValue): "network down"
            case (.posix, POSIXErrorCode.ETIMEDOUT.rawValue): "connection timed out"
            case (.dns, _): "host name lookup failed"
            default: nil
            }
        }

        var description: String {
            let base = "\(domain.rawValue) error \(code)"
            guard let label else { return base }
            return "\(base), \(label)"
        }
    }

    nonisolated enum ProbeResult: Equatable, Sendable {
        case cancelled
        case fingerprint(String)
        case invalidPort
        case noCertificate
        case noHosts
        case timeout
        case tlsFailed(cause: FailureCause)
        case unreachable(cause: FailureCause)

        var abortMessage: String {
            switch self {
            case .invalidPort:
                "Invalid port number. Enter a port between 1 and 65535."
            case .noHosts:
                "No host address to probe. Enter the desktop app's host or Tailcat address."
            case .unreachable(let cause):
                "Could not reach the server (\(cause)). Check the host and port, make sure the desktop app is running, and try again."
            case .timeout:
                "Timed out waiting for the server to respond. Check the host and port, make sure the desktop app is running, and try again."
            case .tlsFailed(let cause):
                "Reached the server, but the TLS handshake failed (\(cause)). Make sure the port is the desktop app's secure connection port."
            case .noCertificate, .fingerprint:
                "The TLS handshake completed, but the server presented no certificate to verify. Pairing requires a pinned certificate, so the connection was aborted."
            case .cancelled:
                "The certificate probe was cancelled."
            }
        }
    }

    nonisolated enum Settlement: Equatable, Sendable {
        case failed(FailureCause)
        case handshakeCompleted
    }

    nonisolated private struct ProbeState: @unchecked Sendable {
        let captured = OSAllocatedUnfairLock<String?>(initialState: nil)
        let settled = OSAllocatedUnfairLock<Settlement?>(initialState: nil)
    }

    static func outcome(forProbe result: ProbeResult) -> Outcome {
        if case .fingerprint(let fingerprint) = result, !fingerprint.isEmpty {
            return .confirmFingerprint(fingerprint)
        }
        return .abort(message: result.abortMessage)
    }

    nonisolated private static let probeTimeoutSeconds = 4
    nonisolated static let probeTimeout: Duration = .seconds(probeTimeoutSeconds)

    nonisolated static func endpointPort(_ port: Int) -> NWEndpoint.Port? {
        guard let raw = UInt16(exactly: port), raw > 0 else { return nil }
        return NWEndpoint.Port(rawValue: raw)
    }

    nonisolated static func fingerprint(fromServerTrust serverTrust: SecTrust) -> String? {
        guard SecTrustGetCertificateCount(serverTrust) > 0,
              let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let serverCert = certChain.first else {
            return nil
        }
        return WebSocketConnection.fingerprint(
            ofCertificate: SecCertificateCopyData(serverCert) as Data
        )
    }

    nonisolated private static func makeProbeConnection(
        host: String,
        port: NWEndpoint.Port,
        state: ProbeState,
        continuation: AsyncStream<Void>.Continuation,
        queue: DispatchQueue
    ) -> NWConnection {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { @Sendable _, trustRef, complete in
                let serverTrust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                if let fingerprint = fingerprint(fromServerTrust: serverTrust) {
                    state.captured.withLock { $0 = fingerprint }
                }
                complete(true)
            },
            queue
        )

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: NWParameters(tls: tlsOptions)
        )
        connection.stateUpdateHandler = { @Sendable connectionState in
            switch connectionState {
            case .setup, .preparing:
                break
            case .ready:
                AppLog.connection.debug("[CertProbe] \(host): handshake completed")
                state.settled.withLock { $0 = $0 ?? .handshakeCompleted }
                continuation.finish()
            case .waiting(let error):
                let cause = FailureCause(error)
                AppLog.connection.debug("[CertProbe] \(host): waiting (\(cause))")
                state.settled.withLock { $0 = $0 ?? .failed(cause) }
                continuation.finish()
            case .failed(let error):
                let cause = FailureCause(error)
                AppLog.connection.debug("[CertProbe] \(host): failed (\(cause))")
                state.settled.withLock { $0 = $0 ?? .failed(cause) }
                continuation.finish()
            case .cancelled:
                continuation.finish()
            @unknown default:
                break
            }
        }
        return connection
    }

    nonisolated private static func awaitProbeSettlement(
        connection: NWConnection,
        queue: DispatchQueue,
        lifecycleEvents: AsyncStream<Void>,
        timeout: Duration
    ) async {
        await withTaskCancellationHandler {
            connection.start(queue: queue)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in lifecycleEvents {}
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                }
                await group.next()
                group.cancelAll()
            }
        } onCancel: {
            connection.cancel()
        }
        connection.cancel()
    }

    nonisolated static func probe(
        host: String,
        port: Int,
        timeout: Duration = probeTimeout
    ) async -> ProbeResult {
        guard let nwPort = endpointPort(port) else { return .invalidPort }

        let state = ProbeState()
        let queue = DispatchQueue(label: "CertFingerprintProbe.\(host)")
        let (lifecycleEvents, lifecycleContinuation) = AsyncStream<Void>.makeStream()
        let connection = makeProbeConnection(
            host: host,
            port: nwPort,
            state: state,
            continuation: lifecycleContinuation,
            queue: queue
        )
        await awaitProbeSettlement(
            connection: connection,
            queue: queue,
            lifecycleEvents: lifecycleEvents,
            timeout: timeout
        )

        let result = classify(
            captured: state.captured.withLock { $0 },
            settled: state.settled.withLock { $0 },
            cancelled: Task.isCancelled
        )
        AppLog.connection.debug("[CertProbe] \(host): \(String(describing: result))")
        return result
    }

    nonisolated static func classify(
        captured: String?, settled: Settlement?, cancelled: Bool
    ) -> ProbeResult {
        if let captured, !captured.isEmpty {
            return .fingerprint(captured)
        }
        if cancelled {
            return .cancelled
        }
        switch settled {
        case .some(.handshakeCompleted):
            return .noCertificate
        case .some(.failed(let cause)):
            return cause.domain == .tls ? .tlsFailed(cause: cause) : .unreachable(cause: cause)
        case .none:
            return .timeout
        }
    }

    nonisolated static func probeFirst(
        hosts: [String],
        port: Int,
        diagnostics: DiagnosticStore = .shared,
        probe: @Sendable (String, Int) async -> ProbeResult = { host, port in
            await Self.probe(host: host, port: port)
        }
    ) async -> ProbeResult {
        var last: ProbeResult = .noHosts
        var hadFailure = false
        for host in hosts {
            last = await probe(host, port)
            switch last {
            case .fingerprint(let fingerprint) where !fingerprint.isEmpty:
                if hadFailure { PairingDiagnostics.phase(.probe, .recovered, store: diagnostics) }
                return last
            case .cancelled:
                return last
            default:
                hadFailure = true
                diagnostics.record(DiagnosticEvent(
                    kind: .pairingPhase,
                    operation: .pairingPhase,
                    site: .trustProbe,
                    stage: .probe,
                    outcome: .fallbackPending,
                    failure: TransportDiagnosticFailure.probe(last),
                    effect: .candidateRejected
                ))
                continue
            }
        }
        return last
    }

    nonisolated static func probeViaTunnel(
        dialer: any TunnelDialing,
        tcAddress: String,
        remotePort: Int,
        probe: @Sendable (String, Int) async -> ProbeResult = { host, port in
            await Self.probe(host: host, port: port)
        }
    ) async throws -> ProbeResult {
        guard endpointPort(remotePort) != nil else { return .invalidPort }
        let tunnel = try await dialer.open(tcAddress: tcAddress, remotePort: remotePort)
        let result = await probe("127.0.0.1", tunnel.localPort)
        await tunnel.close()
        return result
    }
}

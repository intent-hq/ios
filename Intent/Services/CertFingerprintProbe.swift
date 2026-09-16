import Foundation
import Network
import os

/// Probes a server's TLS certificate fingerprint ahead of pairing, shared by
/// manual token entry and QR pairing payloads that carry no fingerprint.
/// Pairing connections must always be pinned: a missing fingerprint aborts
/// instead of falling back to plain WS.
///
/// Built on Network.framework (NWConnection) like WebSocketConnection:
/// URLSession is deliberately not used because App Transport Security aborts
/// the TLS handshake to non-local hosts (public IPs, Tailscale) before the
/// server-trust delegate ever runs, so the fingerprint could never be
/// captured for remote daemons.
enum CertFingerprintProbe {
    /// Decision for a completed TLS probe.
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

    /// Safe-by-construction rendering of the NWError behind a probe failure:
    /// a static domain name plus the numeric code (and a static label for
    /// well-known codes). Never carries foreign error strings, hosts, or
    /// user input, so it can be shown to the user in Release builds.
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

        /// Static label for well-known codes; nil for everything else.
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

    /// Typed result of a probe. Every failure keeps the stage it failed at
    /// (and the cause where the network stack reports one) so callers can
    /// tell an unreachable endpoint from a TLS problem instead of collapsing
    /// everything to "no certificate".
    nonisolated enum ProbeResult: Equatable, Sendable {
        /// The probing task was cancelled before it settled.
        case cancelled
        /// The handshake presented a leaf certificate; its fingerprint.
        case fingerprint(String)
        /// The port is outside 1...65535; nothing was dialed.
        case invalidPort
        /// The handshake completed without presenting a certificate.
        case noCertificate
        /// No host was given to probe; nothing was dialed.
        case noHosts
        /// Neither a handshake nor a failure arrived within the deadline.
        case timeout
        /// TCP connected, but the TLS handshake failed (e.g. a plain-TCP or
        /// HTTP listener on that port).
        case tlsFailed(cause: FailureCause)
        /// The TCP connection never came up (refused, unroutable, DNS).
        case unreachable(cause: FailureCause)

        /// User-facing abort message naming the stage that failed. An empty
        /// `.fingerprint` is the degenerate no-certificate case.
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

    /// How the NWConnection behind a probe settled, if it did before the
    /// deadline.
    nonisolated enum Settlement: Equatable, Sendable {
        /// `.waiting` / `.failed` with the reported error.
        case failed(FailureCause)
        /// `.ready`: the TLS handshake completed.
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

    /// Per-host probe deadline. Fail fast on unroutable hosts: a multi-host
    /// QR payload probes hosts sequentially, so a hung host would otherwise
    /// stall the pairing spinner for minutes. 4s matches the websocket
    /// timeout ConnectionManager.raceHosts uses per host.
    nonisolated private static let probeTimeoutSeconds = 4
    nonisolated static let probeTimeout: Duration = .seconds(probeTimeoutSeconds)

    /// Validated NWEndpoint.Port for a user-supplied port number, or nil when
    /// the value is outside 1...65535 (pure, unit-testable).
    nonisolated static func endpointPort(_ port: Int) -> NWEndpoint.Port? {
        guard let raw = UInt16(exactly: port), raw > 0 else { return nil }
        return NWEndpoint.Port(rawValue: raw)
    }

    /// Normalized fingerprint of the leaf certificate in a server trust, or
    /// nil when no certificate is presented (unit-testable — the verify block
    /// below is only the NW wiring around this).
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
            { _, trustRef, complete in
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
        connection.stateUpdateHandler = { connectionState in
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

    /// Probe the server's TLS certificate fingerprint via a bare TLS
    /// handshake — no HTTP request is needed, the handshake alone yields the
    /// certificate. Every failure keeps its stage (`ProbeResult`): timeout,
    /// unreachable host, TLS handshake failure, or a handshake that presented
    /// no certificate.
    ///
    /// Must be nonisolated: the module's default actor isolation is MainActor,
    /// and the verify block / stateUpdateHandler closures formed here inherit
    /// the function's isolation. boringssl invokes the verify block on the
    /// probe's private queue, where an inherited MainActor assertion traps
    /// (EXC_BREAKPOINT in dispatch_assert_queue_fail).
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

    /// Pure mapping from what the probe observed to a `ProbeResult`: a
    /// captured fingerprint wins outright; otherwise the settlement names the
    /// failing stage — a TLS-domain error means TCP connected and the
    /// handshake failed, any other error means the endpoint was unreachable,
    /// a completed handshake without a fingerprint means no certificate was
    /// presented, and no settlement at all is a timeout.
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

    /// Probe hosts in order and return the first fingerprint found; when no
    /// host yields one, the result of the last host probed (so the stage and
    /// cause of the failure survive). Nonisolated for the same reason as
    /// `probe(host:port:)`. The probe function is injectable for tests.
    nonisolated static func probeFirst(
        hosts: [String],
        port: Int,
        probe: @Sendable (String, Int) async -> ProbeResult = { host, port in
            await Self.probe(host: host, port: port)
        }
    ) async -> ProbeResult {
        var last: ProbeResult = .noHosts
        for host in hosts {
            last = await probe(host, port)
            switch last {
            case .fingerprint(let fingerprint) where !fingerprint.isEmpty:
                return last
            case .cancelled:
                return last
            default:
                continue
            }
        }
        return last
    }

    /// Probe the daemon's certificate fingerprint through a tailcat tunnel
    /// (manual tc-address entry): opens the tunnel, probes its loopback
    /// forwarder, and closes the tunnel — pairing over the tunnel stays
    /// pinned exactly like direct hosts. An out-of-range `remotePort` is
    /// rejected as `.invalidPort` before any tunnel is dialed, matching the
    /// direct path. Throws when the tunnel cannot be dialed (invalid or
    /// unreachable tc address); a non-fingerprint result means the tunnel
    /// came up but the probe through it failed at the stage the result
    /// names. The probe function is injectable for tests;
    /// production uses the real TLS probe above. It must stay non-throwing:
    /// the close-on-all-paths guarantee relies on the linear open → probe →
    /// close flow (`defer { await close() }` is not expressible), so a
    /// throwing probe would leak the tunnel.
    /// Nonisolated for the same reason as `probe(host:port:)`.
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

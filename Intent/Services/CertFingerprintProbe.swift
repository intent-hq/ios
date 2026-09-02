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
        case confirmFingerprint(String)
        case abort(message: String)
    }

    static let noCertErrorMessage =
        "Could not verify the server's TLS certificate. Check the host and port, make sure the desktop app is running, and try again."

    static func outcome(forFingerprint fingerprint: String?) -> Outcome {
        if let fingerprint, !fingerprint.isEmpty {
            return .confirmFingerprint(fingerprint)
        }
        return .abort(message: noCertErrorMessage)
    }

    /// Per-host probe deadline. Fail fast on unroutable hosts: a multi-host
    /// QR payload probes hosts sequentially, so a hung host would otherwise
    /// stall the pairing spinner for minutes. 4s matches the websocket
    /// timeout ConnectionManager.raceHosts uses per host.
    static let probeTimeout: Duration = .seconds(4)

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
            ofCertificate: SecCertificateCopyData(serverCert) as Data)
    }

    /// Probe the server's TLS certificate fingerprint via a bare TLS
    /// handshake — no HTTP request is needed, the handshake alone yields the
    /// certificate. Returns nil on timeout, unreachable hosts, or plain-TCP
    /// refusals.
    ///
    /// Must be nonisolated: the module's default actor isolation is MainActor,
    /// and the verify block / stateUpdateHandler closures formed here inherit
    /// the function's isolation. boringssl invokes the verify block on the
    /// probe's private queue, where an inherited MainActor assertion traps
    /// (EXC_BREAKPOINT in dispatch_assert_queue_fail).
    nonisolated static func probe(host: String, port: Int) async -> String? {
        guard let nwPort = endpointPort(port) else { return nil }

        let captured = OSAllocatedUnfairLock<String?>(initialState: nil)
        let queue = DispatchQueue(label: "CertFingerprintProbe.\(host)")
        let (lifecycleEvents, lifecycleContinuation) = AsyncStream<Void>.makeStream()

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, trustRef, complete in
                let serverTrust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                if let fingerprint = fingerprint(fromServerTrust: serverTrust) {
                    captured.withLock { $0 = fingerprint }
                }
                // Accept the handshake: trust is informational only for the
                // probe — the fingerprint is surfaced to the user to confirm
                // and the connection is closed immediately after capture.
                complete(true)
            },
            queue)

        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: tlsOptions))
        connection.stateUpdateHandler = { state in
            switch state {
            case .setup, .preparing:
                break
            case .ready:
                AppLog.connection.debug("[CertProbe] \(host): handshake completed")
                lifecycleContinuation.finish()
            case .waiting(let error):
                // NWConnection retries in .waiting on unreachable/refusing
                // hosts; treat it as terminal so sequential probing moves on.
                AppLog.connection.debug("[CertProbe] \(host): waiting (\(String(describing: error)))")
                lifecycleContinuation.finish()
            case .failed(let error):
                AppLog.connection.debug("[CertProbe] \(host): failed (\(String(describing: error)))")
                lifecycleContinuation.finish()
            case .cancelled:
                lifecycleContinuation.finish()
            @unknown default:
                break
            }
        }

        await withTaskCancellationHandler {
            connection.start(queue: queue)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    // No values are ever yielded; the stream just terminates
                    // when the handshake settles.
                    for await _ in lifecycleEvents {}
                }
                group.addTask {
                    try? await Task.sleep(for: probeTimeout)
                }
                await group.next()
                group.cancelAll()
            }
        } onCancel: {
            connection.cancel()
        }
        connection.cancel()

        return captured.withLock { $0 }
    }

    /// Probe hosts in order and return the first fingerprint found, or nil
    /// when no host yields a certificate. Nonisolated for the same reason as
    /// `probe(host:port:)`.
    nonisolated static func probeFirst(hosts: [String], port: Int) async -> String? {
        for host in hosts {
            if let fingerprint = await probe(host: host, port: port), !fingerprint.isEmpty {
                return fingerprint
            }
        }
        return nil
    }

    /// Probe the daemon's certificate fingerprint through a tailcat tunnel
    /// (manual tc-address entry): opens the tunnel, probes its loopback
    /// forwarder, and closes the tunnel — pairing over the tunnel stays
    /// pinned exactly like direct hosts. Throws when the tunnel cannot be
    /// dialed (invalid or unreachable tc address); a nil return means the
    /// tunnel came up but no certificate was captured. The probe function is
    /// injectable for tests; production uses the real TLS probe above. It must
    /// stay non-throwing: the close-on-all-paths guarantee relies on the
    /// linear open → probe → close flow (`defer { await close() }` is not
    /// expressible), so a throwing probe would leak the tunnel.
    /// Nonisolated for the same reason as `probe(host:port:)`.
    nonisolated static func probeViaTunnel(
        dialer: any TunnelDialing,
        tcAddress: String,
        remotePort: Int,
        probe: @Sendable (String, Int) async -> String? = { await Self.probe(host: $0, port: $1) }
    ) async throws -> String? {
        let tunnel = try await dialer.open(tcAddress: tcAddress, remotePort: remotePort)
        let fingerprint = await probe("127.0.0.1", tunnel.localPort)
        await tunnel.close()
        return fingerprint
    }
}

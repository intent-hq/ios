import Foundation
import Network
import Security
import Testing
import os
@testable import Intent

/// Regression coverage for the pairing TLS probe decision (shared by manual
/// entry and fingerprint-less QR payloads): pairing connections must always
/// be pinned, so a probe that finds no certificate aborts with an error
/// instead of falling back to an unpinned plain-WS connection.
struct ManualTokenEntryViewTests {

    private typealias ProbeResult = CertFingerprintProbe.ProbeResult
    private typealias FailureCause = CertFingerprintProbe.FailureCause

    @Test @MainActor func probedFingerprintLeadsToConfirmation() {
        let fingerprint = "ab:cd:ef:01"
        let outcome = CertFingerprintProbe.outcome(forProbe: .fingerprint(fingerprint))
        #expect(outcome == .confirmFingerprint(fingerprint))
    }

    @Test @MainActor func noCertificateAbortsInsteadOfConnectingUnpinned() {
        let outcome = CertFingerprintProbe.outcome(forProbe: .noCertificate)
        #expect(outcome == .abort(message: ProbeResult.noCertificate.abortMessage))
    }

    @Test @MainActor func emptyFingerprintAbortsInsteadOfConnectingUnpinned() {
        let outcome = CertFingerprintProbe.outcome(forProbe: .fingerprint(""))
        #expect(outcome == .abort(message: ProbeResult.noCertificate.abortMessage))
    }

    // MARK: - Failure stage and cause (ios#233): each failure names the
    // stage it failed at instead of collapsing to one generic message.

    @Test @MainActor func everyFailureStageAbortsWithADistinctMessage() {
        let refused = FailureCause(domain: .posix, code: POSIXErrorCode.ECONNREFUSED.rawValue)
        let tls = FailureCause(domain: .tls, code: -9836)
        let failures: [ProbeResult] = [
            .invalidPort, .noHosts, .unreachable(cause: refused), .timeout,
            .tlsFailed(cause: tls), .noCertificate, .cancelled,
        ]
        var messages = Set<String>()
        for failure in failures {
            let outcome = CertFingerprintProbe.outcome(forProbe: failure)
            #expect(outcome == .abort(message: failure.abortMessage))
            messages.insert(failure.abortMessage)
        }
        #expect(messages.count == failures.count, "Each failure stage needs its own message")
    }

    @Test func failureMessagesNameTheStageAndCause() {
        let refused = FailureCause(domain: .posix, code: POSIXErrorCode.ECONNREFUSED.rawValue)
        let unreachable = ProbeResult.unreachable(cause: refused).abortMessage
        #expect(unreachable.contains("Could not reach the server"))
        #expect(unreachable.contains("POSIX error 61, connection refused"))

        let tls = ProbeResult.tlsFailed(cause: FailureCause(domain: .tls, code: -9836)).abortMessage
        #expect(tls.contains("TLS handshake failed"))
        #expect(tls.contains("TLS error -9836"))

        #expect(ProbeResult.timeout.abortMessage.contains("Timed out"))
        #expect(ProbeResult.noCertificate.abortMessage.contains("no certificate"))
        #expect(ProbeResult.invalidPort.abortMessage.contains("1 and 65535"))
    }

    @Test func failureCauseRendersOnlyStaticDomainCodeAndLabel() {
        #expect(FailureCause(domain: .posix, code: POSIXErrorCode.EHOSTUNREACH.rawValue).description
            == "POSIX error 65, host unreachable")
        #expect(FailureCause(domain: .posix, code: POSIXErrorCode.ETIMEDOUT.rawValue).description
            == "POSIX error 60, connection timed out")
        #expect(FailureCause(domain: .posix, code: 1).description == "POSIX error 1")
        #expect(FailureCause(domain: .dns, code: -65554).description
            == "DNS error -65554, host name lookup failed")
        #expect(FailureCause(domain: .tls, code: -9806).description == "TLS error -9806")
        #expect(FailureCause(.posix(.ECONNRESET)) == FailureCause(domain: .posix, code: 54))
        #expect(FailureCause(.tls(-9836)) == FailureCause(domain: .tls, code: -9836))
    }

    @Test func classifyMapsObservationsToStages() {
        let refused = FailureCause(domain: .posix, code: POSIXErrorCode.ECONNREFUSED.rawValue)
        let dns = FailureCause(domain: .dns, code: -65554)
        let tls = FailureCause(domain: .tls, code: -9836)
        #expect(CertFingerprintProbe.classify(
            captured: "ab:cd", settled: .failed(tls), cancelled: false) == .fingerprint("ab:cd"))
        #expect(CertFingerprintProbe.classify(
            captured: nil, settled: nil, cancelled: false) == .timeout)
        #expect(CertFingerprintProbe.classify(
            captured: nil, settled: .handshakeCompleted, cancelled: false) == .noCertificate)
        #expect(CertFingerprintProbe.classify(
            captured: "", settled: .handshakeCompleted, cancelled: false) == .noCertificate)
        #expect(CertFingerprintProbe.classify(
            captured: nil, settled: .failed(refused), cancelled: false) == .unreachable(cause: refused))
        #expect(CertFingerprintProbe.classify(
            captured: nil, settled: .failed(dns), cancelled: false) == .unreachable(cause: dns))
        #expect(CertFingerprintProbe.classify(
            captured: nil, settled: .failed(tls), cancelled: false) == .tlsFailed(cause: tls))
        #expect(CertFingerprintProbe.classify(
            captured: nil, settled: nil, cancelled: true) == .cancelled)
    }

    @Test func probeFirstReturnsFirstFingerprintOrLastFailure() async {
        let refused = ProbeResult.unreachable(
            cause: FailureCause(domain: .posix, code: POSIXErrorCode.ECONNREFUSED.rawValue))
        let tried = OSAllocatedUnfairLock<[String]>(initialState: [])

        let found = await CertFingerprintProbe.probeFirst(hosts: ["a", "b", "c"], port: 1) { host, _ in
            tried.withLock { $0.append(host) }
            return host == "b" ? .fingerprint("ab:cd") : refused
        }
        #expect(found == .fingerprint("ab:cd"))
        #expect(tried.withLock { $0 } == ["a", "b"])

        let allFailed = await CertFingerprintProbe.probeFirst(hosts: ["a", "b"], port: 1) { host, _ in
            host == "a" ? .timeout : refused
        }
        #expect(allFailed == refused, "The last host's failure stage must survive")

        #expect(await CertFingerprintProbe.probeFirst(hosts: [], port: 1) { _, _ in .timeout } == .noHosts)
    }

    @Test func endpointPortAcceptsValidRange() {
        #expect(CertFingerprintProbe.endpointPort(1)?.rawValue == 1)
        #expect(CertFingerprintProbe.endpointPort(7550)?.rawValue == 7550)
        #expect(CertFingerprintProbe.endpointPort(65535)?.rawValue == 65535)
    }

    @Test func endpointPortRejectsOutOfRangeValues() {
        #expect(CertFingerprintProbe.endpointPort(0) == nil)
        #expect(CertFingerprintProbe.endpointPort(-1) == nil)
        #expect(CertFingerprintProbe.endpointPort(65536) == nil)
    }

    @Test func probeReportsInvalidPortWithoutConnecting() async {
        #expect(await CertFingerprintProbe.probe(host: "192.0.2.1", port: 0) == .invalidPort)
        #expect(await CertFingerprintProbe.probe(host: "192.0.2.1", port: 65536) == .invalidPort)
    }

    @Test func probeTimeoutMatchesPerHostWebSocketTimeout() {
        #expect(CertFingerprintProbe.probeTimeout == WebSocketConnection.connectTimeout)
    }

    // MARK: - Trust fingerprint extraction (the capture path of the probe's
    // TLS verify block, factored so it is testable without a live handshake)

    /// Self-signed DER certificate fixture (CN=CertFingerprintProbe Test
    /// Fixture) with its independently computed SHA-256 fingerprint
    /// (openssl dgst -sha256 -c), pinning the normalization end to end.
    private static let fixtureCertDERBase64 = """
        MIIBrTCCAVOgAwIBAgIUR7S/oedy6Qg4laIDRfAbIuYBqn8wCgYIKoZIzj0EAwIw\
        LDEqMCgGA1UEAwwhQ2VydEZpbmdlcnByaW50UHJvYmUgVGVzdCBGaXh0dXJlMB4X\
        DTI2MDgyOTEwMTEyMloXDTM2MDgyNjEwMTEyMlowLDEqMCgGA1UEAwwhQ2VydEZp\
        bmdlcnByaW50UHJvYmUgVGVzdCBGaXh0dXJlMFkwEwYHKoZIzj0CAQYIKoZIzj0D\
        AQcDQgAEVkKimPx0hA3zbzxwyqiGHf0H49UX0KjPyUXVA+vr7f7mAxj2e95Ag40q\
        EfjVSlQ86fh6AKRVirbc8sBcc27OH6NTMFEwHQYDVR0OBBYEFKOd1uZkcxPWviCp\
        MGasqz4joZjIMB8GA1UdIwQYMBaAFKOd1uZkcxPWviCpMGasqz4joZjIMA8GA1Ud\
        EwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIhAO+/RKPbc1iCKK/jXutrkiI3\
        slELtPaJNU4NbTHFHa2nAiAdM9J2cpWId3aYi3to72sTXOinhpR8SsRaqppIuuWw\
        0A==
        """
    private static let fixtureCertFingerprint =
        "fb:3b:01:08:d8:20:77:6e:34:31:21:25:24:64:3e:95:91:bf:b4:4a:3d:80:cf:77:e5:a8:46:a0:48:90:eb:aa"

    private static func fixtureServerTrust() throws -> SecTrust {
        let der = try #require(Data(base64Encoded: fixtureCertDERBase64))
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }

    @Test func trustFingerprintMatchesOpenSSLDigestOfLeafCertificate() throws {
        let trust = try Self.fixtureServerTrust()
        #expect(CertFingerprintProbe.fingerprint(fromServerTrust: trust) == Self.fixtureCertFingerprint)
    }

    @Test func trustFingerprintUsesSharedTransportNormalization() throws {
        let der = try #require(Data(base64Encoded: Self.fixtureCertDERBase64))
        let trust = try Self.fixtureServerTrust()
        #expect(CertFingerprintProbe.fingerprint(fromServerTrust: trust)
            == WebSocketConnection.fingerprint(ofCertificate: der))
    }

    // MARK: - Live TLS handshake (regression for the verify-block MainActor
    // crash: probe must be nonisolated, so boringssl can invoke its verify
    // block on the probe's private queue without tripping a MainActor
    // assertion — EXC_BREAKPOINT in dispatch_assert_queue_fail)

    /// PKCS#12 bundle (password "fixture") with a self-signed EC P-256
    /// identity (CN=CertFingerprintProbe Live Handshake Fixture), plus the
    /// leaf certificate's independently computed SHA-256 fingerprint
    /// (openssl dgst -sha256 -c).
    private nonisolated static let fixtureIdentityP12Base64 = """
        MIIDwgIBAzCCA4gGCSqGSIb3DQEHAaCCA3kEggN1MIIDcTCCAmcGCSqGSIb3DQEH\
        BqCCAlgwggJUAgEAMIICTQYJKoZIhvcNAQcBMBwGCiqGSIb3DQEMAQMwDgQIKjGU\
        RG5CHioCAggAgIICIKX4vqHc5LEBJoDk4LCj/2pjqp2i0Nj/U90hNmNOivkfyHi7\
        Zg6RGayCQeu48tFEdjLQDjJ/sgB/wlLjp7R5Ap0F49NcQOeARGb8BeoTDTnvr7Vd\
        sF8YEPl2Jx3fdX1eb350GOvXnt7N0/usCWOrD6uAjlRsWRg/X1kdnizF+xi1RBBP\
        DQl02aRJFKpEbW0hj153xbtJwLmHRqX5IcD5F7PYu3XLZW17lnJeqzxcxfcug3Du\
        s3Jw4aO1RgRKtlZEeuC+5idLYRlsehVixnv7nq64ufC04pUWW4l1n9zwIblvbyWA\
        L5zrB0Z4t5mThLVXTx/hu+Y6Tk40+wEyKrjQpotJ2Udp2f5EtGz2w8juWn+EQ/c+\
        tdORutmphlKe3iHVsIFvQFwlbDU5yVZPTdL/SGOT4uHkHFaey6Gd2LUg6w4cxwwC\
        JmOuGjKk++GjgkxzErhgfg4fpleCpEhCT7D40Rt1V1F5t8JAC5XZvL6tod6dUQMd\
        qiNCxNWugjbe5fThie+KChM9rhRiBQC0Ia7wMBIn6ngKgS7KforZjPLhJzcuBICa\
        4sc+mGy/nfa94Ok2jFn0LyyRDv9lUxE5QlNwcdox+dI0EPvQep2DmVBF9gyd4/OH\
        vtR0AlBG+GXDwHnPf6zUtaDlhpy81luyPUBTHsMTiqWBlQVNwejDMaflA3DkmBP3\
        1KvLX1OjR4j1Y0BDapXHnWy2TaTpTdbVShG3J1MwggECBgkqhkiG9w0BBwGggfQE\
        gfEwge4wgesGCyqGSIb3DQEMCgECoIG0MIGxMBwGCiqGSIb3DQEMAQMwDgQIDbzJ\
        PbDzUgYCAggABIGQvP15S6ZH8rNJVdwRKKC+TI1bZI6rChENTizhb1wcsFZnV3Qu\
        Jn4IEGvIQJ2PnQbfNt3HwM4TkkAM+psWzJxXpOYMdQwlPDmvhAebBw5PZAd/7C4W\
        QPtyzskZwTPR6NFrSmVkK+g8GLwu1FOIFyvTckq00zkjpklzrlLx095KHGOCLrwl\
        bdQ5seTuC+Asu0l5MSUwIwYJKoZIhvcNAQkVMRYEFBn1nLh9mgTHWR2N/1J7+Zzj\
        UrVnMDEwITAJBgUrDgMCGgUABBQ2+7hWu5Qe6SsZHyl7pq9jBLcTsQQIfjmQQ3oB\
        8nUCAggA
        """
    private nonisolated static let fixtureIdentityFingerprint =
        "e7:24:5c:fe:e7:65:5b:70:6b:e9:7e:02:1f:81:dc:f5:a1:15:38:8c:d1:a3:5f:22:90:08:f6:5e:97:3c:cc:ea"

    private nonisolated static func fixtureIdentity() throws -> SecIdentity {
        let p12 = try #require(Data(base64Encoded: fixtureIdentityP12Base64))
        var items: CFArray?
        let status = SecPKCS12Import(
            p12 as CFData,
            [kSecImportExportPassphrase as String: "fixture"] as CFDictionary,
            &items)
        #expect(status == errSecSuccess)
        let dicts = try #require(items as? [[String: Any]])
        let first = try #require(dicts.first)
        let identity = try #require(first[kSecImportItemIdentity as String])
        return identity as! SecIdentity
    }

    /// Starts a loopback TLS listener serving the fixture identity and waits
    /// until it is ready. Nonisolated for the same reason as the probe itself:
    /// the handlers formed here run on the listener queue and must not inherit
    /// MainActor isolation.
    private nonisolated static func startTLSListener() async throws -> NWListener {
        let identity = try fixtureIdentity()
        let tlsOptions = NWProtocolTLS.Options()
        let secIdentity = try #require(sec_identity_create(identity))
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
        let listener = try NWListener(using: NWParameters(tls: tlsOptions), on: .any)
        let queue = DispatchQueue(label: "ManualTokenEntryViewTests.tls-listener")
        // Retain accepted connections for the listener's lifetime: an
        // unreferenced NWConnection can deallocate and cancel the handshake
        // before the probe captures the certificate.
        let accepted = OSAllocatedUnfairLock(initialState: [NWConnection]())
        listener.newConnectionHandler = { connection in
            accepted.withLock { $0.append(connection) }
            connection.start(queue: queue)
        }
        let resumed = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    let alreadyResumed = resumed.withLock { (done: inout Bool) -> Bool in
                        let was = done
                        done = true
                        return was
                    }
                    if !alreadyResumed { continuation.resume() }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return listener
    }

    /// Full probe against a live local TLS handshake. Before probe was marked
    /// nonisolated this crashed instead of failing: the verify block inherited
    /// MainActor isolation and trapped when boringssl invoked it on the
    /// probe's queue.
    @Test func probeCapturesFingerprintViaLiveTLSHandshake() async throws {
        let listener = try await Self.startTLSListener()
        defer { listener.cancel() }
        let port = try #require(listener.port?.rawValue)
        let result = await CertFingerprintProbe.probe(host: "127.0.0.1", port: Int(port))
        #expect(result == .fingerprint(Self.fixtureIdentityFingerprint))
    }

    /// Starts a plain-TCP loopback listener and waits until it is ready. Each
    /// accepted connection is handed to `onAccept` on the listener queue.
    private nonisolated static func startTCPListener(
        onAccept: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> NWListener {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "ManualTokenEntryViewTests.tcp-listener")
        let accepted = OSAllocatedUnfairLock(initialState: [NWConnection]())
        listener.newConnectionHandler = { connection in
            accepted.withLock { $0.append(connection) }
            connection.start(queue: queue)
            onAccept(connection)
        }
        let resumed = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    let alreadyResumed = resumed.withLock { (done: inout Bool) -> Bool in
                        let was = done
                        done = true
                        return was
                    }
                    if !alreadyResumed { continuation.resume() }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return listener
    }

    /// Nothing listening on the port: the TCP connect is refused, which must
    /// surface as unreachable (with the POSIX cause) — not as "no certificate".
    @Test func probeReportsUnreachableWhenConnectionIsRefused() async throws {
        let listener = try await Self.startTCPListener { _ in }
        let port = try #require(listener.port?.rawValue)
        listener.cancel()
        try await Task.sleep(for: .milliseconds(100))

        let result = await CertFingerprintProbe.probe(host: "127.0.0.1", port: Int(port))
        guard case .unreachable(let cause) = result else {
            Issue.record("Expected .unreachable, got \(result)")
            return
        }
        #expect(cause.domain == .posix)
        #expect(cause.code == POSIXErrorCode.ECONNREFUSED.rawValue)
    }

    /// A listener that accepts TCP but never answers the ClientHello: neither
    /// a handshake nor an error settles the connection, so the probe must
    /// report a timeout — not "no certificate".
    @Test func probeReportsTimeoutWhenServerNeverAnswersHandshake() async throws {
        let listener = try await Self.startTCPListener { _ in }
        defer { listener.cancel() }
        let port = try #require(listener.port?.rawValue)

        let result = await CertFingerprintProbe.probe(
            host: "127.0.0.1", port: Int(port), timeout: .milliseconds(500))
        #expect(result == .timeout)
    }

    /// A plain-TCP listener answering with non-TLS bytes (an HTTP server on
    /// the wrong port): TCP connects, the handshake fails, and the probe must
    /// report a TLS failure with the cause — not "no certificate".
    @Test func probeReportsTLSFailureWhenServerSpeaksPlainText() async throws {
        let listener = try await Self.startTCPListener { connection in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                connection.send(
                    content: Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in })
            }
        }
        defer { listener.cancel() }
        let port = try #require(listener.port?.rawValue)

        let result = await CertFingerprintProbe.probe(host: "127.0.0.1", port: Int(port))
        guard case .tlsFailed(let cause) = result else {
            Issue.record("Expected .tlsFailed, got \(result)")
            return
        }
        #expect(cause.domain == .tls)
    }

    /// Cancelling the probing task (the user hit Cancel) reports `.cancelled`
    /// rather than a misleading timeout or certificate error.
    @Test func probeReportsCancellationWhenTaskIsCancelled() async throws {
        let listener = try await Self.startTCPListener { _ in }
        defer { listener.cancel() }
        let port = try #require(listener.port?.rawValue)

        let task = Task {
            await CertFingerprintProbe.probe(host: "127.0.0.1", port: Int(port))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        #expect(await task.value == .cancelled)
    }

    // MARK: - Input classification (direct host vs Tailcat connection blob)

    /// Generated offline with pinned tailcat v0.4.0's `ConnInfo.ConnBlob` from
    /// distinct deterministic 32-byte node/disco public keys and RegionID 10.
    /// It contains no private key, token, or other credential.
    private static let syntheticSDKConnBlob =
        "tco2FwWCABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fIGFrWCChoqOkpaanqKmqq6ytrq-wsbKztLW2t7i5uru8vb6_wGFpCg"

    private static func decodedSyntheticSDKConnBlob() throws -> Data {
        var base64 = String(syntheticSDKConnBlob.dropFirst(2))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return try #require(Data(base64Encoded: base64))
    }

    @Test func syntheticSDKConnectionBlobMatchesPinnedServerShape() throws {
        let decoded = try Self.decodedSyntheticSDKConnBlob()
        #expect(decoded.count == 76)
        #expect(decoded[0] == 0xa3)
        #expect(decoded[1..<5].elementsEqual([0x61, 0x70, 0x58, 0x20]))
        #expect(decoded[5..<37].elementsEqual((1...32).map(UInt8.init)))
        #expect(decoded[37..<41].elementsEqual([0x61, 0x6b, 0x58, 0x20]))
        #expect(decoded[41..<73].elementsEqual((0xa1...0xc0).map(UInt8.init)))
        #expect(decoded[73..<76].elementsEqual([0x61, 0x69, 0x0a]))
    }

    @Test func classifiesSDKConnectionBlobAsTailcatWithoutChangingEncodedCase() {
        #expect(Self.syntheticSDKConnBlob != Self.syntheticSDKConnBlob.lowercased())
        #expect(ManualConnectionInput.classify(Self.syntheticSDKConnBlob)
            == .tailcat(tcAddress: Self.syntheticSDKConnBlob))
    }

    @Test func classificationToleratesPasteArtifacts() {
        #expect(ManualConnectionInput.classify("  \(Self.syntheticSDKConnBlob)\n")
            == .tailcat(tcAddress: Self.syntheticSDKConnBlob))
    }

    @Test func classifiesHostnamesIPsAndNearMissesAsDirect() {
        #expect(ManualConnectionInput.classify("example.com") == .direct(host: "example.com"))
        #expect(ManualConnectionInput.classify("192.168.1.10") == .direct(host: "192.168.1.10"))
        #expect(ManualConnectionInput.classify("tcp-server.local") == .direct(host: "tcp-server.local"))
        #expect(ManualConnectionInput.classify("tchost") == .direct(host: "tchost"))
        #expect(ManualConnectionInput.classify("tcoA") == .direct(host: "tcoA"))
        #expect(ManualConnectionInput.classify("tc-key-abc123") == .direct(host: "tc-key-abc123"))
        #expect(ManualConnectionInput.classify("tco.example.com") == .direct(host: "tco.example.com"))
        #expect(ManualConnectionInput.classify("") == .direct(host: ""))
        #expect(ManualConnectionInput.classify(" 10.0.0.7 ") == .direct(host: "10.0.0.7"))
    }

    @Test func directInputConnectsExactlyAsToday() {
        let input = ManualConnectionInput.classify("192.168.1.42")
        #expect(input.hosts == ["192.168.1.42"])
        #expect(input.tcAddress == nil)
    }

    @Test func tailcatInputConnectsTunnelOnly() {
        let input = ManualConnectionInput.classify(Self.syntheticSDKConnBlob)
        #expect(input.hosts == [])
        #expect(input.tcAddress == Self.syntheticSDKConnBlob)
    }

    // MARK: - Fingerprint probe through the tailcat tunnel (mock dialer)

    private nonisolated final class FakeTunnelSession: TunnelSession, @unchecked Sendable {
        let localPort: Int
        private let closed = OSAllocatedUnfairLock(initialState: false)
        init(localPort: Int) { self.localPort = localPort }
        func close() async { closed.withLock { $0 = true } }
        var isClosed: Bool { closed.withLock { $0 } }
    }

    private nonisolated struct FakeTunnelDialer: TunnelDialing {
        let result: Result<FakeTunnelSession, WebSocketTransportError>
        let observed = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])
        func open(tcAddress: String, remotePort: Int) async throws -> any TunnelSession {
            observed.withLock { $0[tcAddress] = remotePort }
            return try result.get()
        }
    }

    /// The tunnel probe dials the tc address with the daemon's WSS port and
    /// probes the tunnel's loopback forwarder — never the tc address itself.
    @Test func probeViaTunnelProbesLoopbackForwarderAndClosesTunnel() async throws {
        let tunnel = FakeTunnelSession(localPort: 45_678)
        let dialer = FakeTunnelDialer(result: .success(tunnel))
        let probed = OSAllocatedUnfairLock<[String]>(initialState: [])

        let result = try await CertFingerprintProbe.probeViaTunnel(
            dialer: dialer, tcAddress: Self.syntheticSDKConnBlob, remotePort: 5181
        ) { host, port in
            probed.withLock { $0.append("\(host):\(port)") }
            return .fingerprint("ab:cd:ef")
        }

        #expect(result == .fingerprint("ab:cd:ef"))
        #expect(dialer.observed.withLock { $0 } == [Self.syntheticSDKConnBlob: 5181])
        #expect(probed.withLock { $0 } == ["127.0.0.1:45678"])
        #expect(tunnel.isClosed)
    }

    /// A tunnel that comes up but whose probe fails still returns that
    /// failure's stage (the caller aborts unpinned) and never leaks the
    /// session.
    @Test func probeViaTunnelClosesTunnelWhenNoCertificateCaptured() async throws {
        let tunnel = FakeTunnelSession(localPort: 1)
        let dialer = FakeTunnelDialer(result: .success(tunnel))

        let result = try await CertFingerprintProbe.probeViaTunnel(
            dialer: dialer, tcAddress: "tc-key-abc123", remotePort: 5180
        ) { _, _ in .noCertificate }

        #expect(result == .noCertificate)
        #expect(tunnel.isClosed)
    }

    /// A failed tunnel dial (invalid or unreachable tc address) throws so the
    /// view can surface a tunnel-specific error instead of the misleading
    /// no-certificate message.
    @Test func probeViaTunnelThrowsWhenDialFails() async {
        let dialer = FakeTunnelDialer(result: .failure(.failed(
            host: ConnectionManager.tunnelCandidateLabel, message: "bad address")))
        await #expect(throws: WebSocketTransportError.self) {
            _ = try await CertFingerprintProbe.probeViaTunnel(
                dialer: dialer, tcAddress: "tc-nonsense", remotePort: 5180
            ) { _, _ in .noCertificate }
        }
    }
}

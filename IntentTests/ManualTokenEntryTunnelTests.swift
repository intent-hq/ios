import Foundation
@testable import Intent
import os
import Testing

extension ManualTokenEntryViewTests {
    private static let syntheticSDKConnBlob =
        "tco2FwWCABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fIGFrWCChoqOkpaanqKmqq6ytrq-wsbKztLW2t7i5uru8vb6_wGFpCg"
    private static let base64Quantum = 4

    private static func decodedSyntheticSDKConnBlob() throws -> Data {
        var base64 = String(syntheticSDKConnBlob.dropFirst(2))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingCount = (base64Quantum - base64.count % base64Quantum) % base64Quantum
        base64 += String(repeating: "=", count: paddingCount)
        return try #require(Data(base64Encoded: base64))
    }

    @Test func syntheticSDKConnectionBlobMatchesPinnedServerShape() throws {
        let decoded = try Self.decodedSyntheticSDKConnBlob()
        #expect(decoded.count == 76)
        #expect(decoded[0] == 0xA3)
        #expect(decoded[1 ..< 5].elementsEqual([0x61, 0x70, 0x58, 0x20]))
        #expect(decoded[5 ..< 37].elementsEqual((1 ... 32).map(UInt8.init)))
        #expect(decoded[37 ..< 41].elementsEqual([0x61, 0x6B, 0x58, 0x20]))
        #expect(decoded[41 ..< 73].elementsEqual((0xA1 ... 0xC0).map(UInt8.init)))
        #expect(decoded[73 ..< 76].elementsEqual([0x61, 0x69, 0x0A]))
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
        #expect(input.hosts.isEmpty)
        #expect(input.tcAddress == Self.syntheticSDKConnBlob)
    }

    nonisolated private final class FakeTunnelSession: TunnelSession, @unchecked Sendable {
        let localPort: Int
        private let closed = OSAllocatedUnfairLock(initialState: false)

        init(localPort: Int) {
            self.localPort = localPort
        }

        func close() async {
            closed.withLock { $0 = true }
        }

        var isClosed: Bool {
            closed.withLock { $0 }
        }
    }

    nonisolated private struct FakeTunnelDialer: TunnelDialing {
        let result: Result<FakeTunnelSession, WebSocketTransportError>
        let observed = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

        func open(tcAddress: String, remotePort: Int) async throws -> any TunnelSession {
            observed.withLock { $0[tcAddress] = remotePort }
            return try result.get()
        }
    }

    @Test func probeViaTunnelProbesLoopbackForwarderAndClosesTunnel() async throws {
        let tunnel = FakeTunnelSession(localPort: 45_678)
        let dialer = FakeTunnelDialer(result: .success(tunnel))
        let probed = OSAllocatedUnfairLock<[String]>(initialState: [])

        let result = try await CertFingerprintProbe.probeViaTunnel(
            dialer: dialer,
            tcAddress: Self.syntheticSDKConnBlob,
            remotePort: 5181
        ) { host, port in
            probed.withLock { $0.append("\(host):\(port)") }
            return .fingerprint("ab:cd:ef")
        }

        #expect(result == .fingerprint("ab:cd:ef"))
        #expect(dialer.observed.withLock { $0 } == [Self.syntheticSDKConnBlob: 5181])
        #expect(probed.withLock { $0 } == ["127.0.0.1:45678"])
        #expect(tunnel.isClosed)
    }

    @Test func probeViaTunnelClosesTunnelWhenNoCertificateCaptured() async throws {
        let tunnel = FakeTunnelSession(localPort: 1)
        let dialer = FakeTunnelDialer(result: .success(tunnel))

        let result = try await CertFingerprintProbe.probeViaTunnel(
            dialer: dialer,
            tcAddress: "tc-key-abc123",
            remotePort: 5181
        ) { _, _ in .noCertificate }

        #expect(result == .noCertificate)
        #expect(tunnel.isClosed)
    }

    @Test(arguments: [0, -1, 65_536]) func probeViaTunnelRejectsInvalidPortWithoutDialing(port: Int) async throws {
        let tunnel = FakeTunnelSession(localPort: 1)
        let dialer = FakeTunnelDialer(result: .success(tunnel))
        let probed = OSAllocatedUnfairLock(initialState: false)

        let result = try await CertFingerprintProbe.probeViaTunnel(
            dialer: dialer,
            tcAddress: Self.syntheticSDKConnBlob,
            remotePort: port
        ) { _, _ in
            probed.withLock { $0 = true }
            return .fingerprint("ab:cd:ef")
        }

        #expect(result == .invalidPort)
        #expect(dialer.observed.withLock { $0 }.isEmpty)
        #expect(!probed.withLock { $0 })
        #expect(!tunnel.isClosed)
    }

    @Test func probeViaTunnelThrowsWhenDialFails() async {
        let dialer = FakeTunnelDialer(result: .failure(.failed(
            host: ConnectionManager.tunnelCandidateLabel,
            message: "bad address"
        )))
        await #expect(throws: WebSocketTransportError.self) {
            _ = try await CertFingerprintProbe.probeViaTunnel(
                dialer: dialer,
                tcAddress: "tc-nonsense",
                remotePort: 5181
            ) { _, _ in .noCertificate }
        }
    }
}

import Foundation
import Network
import os
import Security
import XCTest

/// A pinned TLS peer in the UI runner, separate from the application under test.
/// Requests go through real host racing, hello admission, polling and reconnect.
nonisolated final class StartupWebSocketFixture: @unchecked Sendable {
    private struct State {
        var connections: [NWConnection] = []
        var snapshot: Data?
        var methods: [String] = []
        var accepts = 0
        var holdStatus = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let listener: NWListener
    private let queue = DispatchQueue(label: "startup-ui-peer")
    var port: Int { Int(listener.port?.rawValue ?? 0) }
    var methods: [String] { state.withLock { $0.methods } }
    var acceptedCount: Int { state.withLock { $0.accepts } }

    init() throws {
        let tls = NWProtocolTLS.Options()
        let identity = try XCTUnwrap(sec_identity_create(Self.identity()))
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            state.withLock { $0.connections.append(connection); $0.accepts += 1 }
            receive(on: connection)
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        dropConnections()
    }

    func dropConnections() {
        let connections = state.withLock { state in
            defer { state.connections.removeAll() }
            return state.connections
        }
        for connection in connections { connection.cancel() }
    }

    func holdStatus() { state.withLock { $0.holdStatus = true } }

    func setPhase(_ phase: String?, estimate: Int? = nil, age: Int = 0) throws {
        let retryMilliseconds = 1000
        let completedNotes = 5
        let totalNotes = 20
        let processedBytes = 50
        let totalBytes = 200
        var snapshot: [String: Any] = [
            "startupStatus": 1, "attemptId": "ui-boot", "phase": phase ?? "ready", "elapsedMs": age,
            "phaseElapsedMs": 0, "progressAgeMs": age, "retryAfterMs": retryMilliseconds,
            "progress": [
                "completedNotes": completedNotes, "totalNotes": totalNotes,
                "processedSourceBytes": processedBytes, "totalSourceBytes": totalBytes
            ]
        ]
        if phase == "finalizing" { snapshot["finalizingStep"] = "committing" }
        if phase == "ready" || phase == "failed" {
            snapshot.removeValue(forKey: "retryAfterMs")
            snapshot["progressAgeMs"] = 0
        }
        if phase == "failed" { snapshot["failure"] = ["code": "startup-failed", "message": "Daemon startup failed. Check daemon logs."] }
        if let estimate { snapshot["estimatedRemainingMs"] = estimate }
        let data = try phase.map { _ in try JSONSerialization.data(withJSONObject: snapshot) }
        state.withLock { $0.snapshot = data; $0.holdStatus = false }
    }

    private func response(id: Any, method: String) -> Data? {
        let current = state.withLock { state in
            state.methods.append(method)
            return (state.snapshot, state.holdStatus)
        }
        if current.1, method == "system.startupStatus" || method == "client.hello" { return nil }
        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let data = current.0, let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if method == "system.startupStatus" {
                response["result"] = snapshot
                if snapshot["phase"] as? String == "ready" { state.withLock { $0.snapshot = nil } }
            } else {
                let notReadyCode = -32_012
                response["error"] = ["code": notReadyCode, "data": ["code": "daemon-not-ready", "startup": snapshot]]
            }
        } else if method == "principal.me" {
            response["result"] = ["id": "test-owner", "isAdministrator": true]
        } else {
            response["result"] = ["server": ["capabilities": [String: Int]()]]
        }
        return try? JSONSerialization.data(withJSONObject: response)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = row["id"], let method = row["method"] as? String,
               let reply = response(id: id, method: method) {
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                connection.send(content: reply, contentContext: .init(identifier: "response", metadata: [metadata]), completion: .idempotent)
            }
            receive(on: connection)
        }
    }
}

nonisolated extension StartupWebSocketFixture {
    private static let fixtureIdentityP12Base64 = """
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
    static let fingerprint =
        "e7:24:5c:fe:e7:65:5b:70:6b:e9:7e:02:1f:81:dc:f5:a1:15:38:8c:d1:a3:5f:22:90:08:f6:5e:97:3c:cc:ea"

    static func identity() throws -> SecIdentity {
        let p12 = try XCTUnwrap(Data(base64Encoded: fixtureIdentityP12Base64))
        var items: CFArray?
        let status = SecPKCS12Import(
            p12 as CFData,
            [kSecImportExportPassphrase as String: "fixture"] as CFDictionary,
            &items
        )
        XCTAssertEqual(status, errSecSuccess)
        let dicts = try XCTUnwrap(items as? [[String: Any]])
        let first = try XCTUnwrap(dicts.first)
        let identity = try XCTUnwrap(first[kSecImportItemIdentity as String])
        // CoreFoundation identities cannot be conditionally cast under Swift 6.4.
        // swiftlint:disable:next force_cast
        return identity as! SecIdentity
    }
}

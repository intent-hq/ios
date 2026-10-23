import Foundation
@testable import Intent
import Testing

extension ConnectionManagerTests {
    /// End-to-end RFC 7692 coverage over real loopback sockets. Nested in the
    /// serialized `ConnectionManagerTests` because the plaintext loopback
    /// override is process-global.
    @Suite struct WebSocketCompressionTests {
        private static let payload = String(repeating: "intentd permessage-deflate ", count: 5000)
        private static let offerHeader = "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits"

        private func connect(
            to server: CompressionWebSocketServer,
            endpoint: WebSocketConnection.Endpoint = .rpc,
            offersCompression: Bool = WebSocketConnection.offersPermessageDeflate
        ) async throws -> WebSocketConnection {
            try await WebSocketConnection.connect(
                host: "127.0.0.1",
                port: server.port,
                token: "token",
                certFingerprint: nil,
                endpoint: endpoint,
                offersCompression: offersCompression
            )
        }

        private func echo(_ text: String, over socket: WebSocketConnection) async throws -> String? {
            try await socket.send(text)
            guard case .string(let echoed) = try await socket.receive() else { return nil }
            return echoed
        }

        private func disconnectCode(_ operation: () async throws -> Void) async -> Int? {
            do {
                try await operation()
            } catch let WebSocketTransportError.disconnected(_, code, _) {
                return code
            } catch {
                Issue.record("unexpected error \(error)")
            }
            return nil
        }

        @Test func compressesBothDirectionsAgainstAcceptingServer() async throws {
            let previous = ConnectionManagerTests.enablePlaintextLoopback()
            defer { ConnectionManagerTests.restorePlaintextLoopback(previous) }

            let compressing = try await CompressionWebSocketServer.start(mode: .acceptDeflate)
            defer { compressing.stop() }
            let socket = try await connect(to: compressing)
            #expect(socket.negotiatedDeflate == PerMessageDeflateParameters())
            #expect(compressing.requestHeaders.contains(Self.offerHeader))
            #expect(try await echo(Self.payload, over: socket) == Self.payload)
            await socket.disconnect()

            let plain = try await CompressionWebSocketServer.start(mode: .decline)
            defer { plain.stop() }
            let control = try await connect(to: plain)
            #expect(control.negotiatedDeflate == nil)
            #expect(try await echo(Self.payload, over: control) == Self.payload)
            await control.disconnect()

            #expect(compressing.clientFrameCompression == [true])
            #expect(plain.clientFrameCompression == [false])
            // Same bar as intentd's wss_deflate_negotiation_compresses_on_the_wire.
            #expect(
                compressing.bytesRead < plain.bytesRead / 2,
                "client→server: deflate=\(compressing.bytesRead)B plain=\(plain.bytesRead)B"
            )
            #expect(
                compressing.bytesWritten < plain.bytesWritten / 2,
                "server→client: deflate=\(compressing.bytesWritten)B plain=\(plain.bytesWritten)B"
            )
        }

        @Test func killSwitchOffSendsNoOfferAndStaysPlain() async throws {
            let previous = ConnectionManagerTests.enablePlaintextLoopback()
            defer { ConnectionManagerTests.restorePlaintextLoopback(previous) }
            let server = try await CompressionWebSocketServer.start(mode: .acceptDeflate)
            defer { server.stop() }

            let socket = try await connect(to: server, offersCompression: false)
            #expect(socket.negotiatedDeflate == nil)
            #expect(!server.requestHeaders.contains { $0.lowercased().hasPrefix("sec-websocket-extensions") })
            #expect(try await echo(Self.payload, over: socket) == Self.payload)
            #expect(server.clientFrameCompression == [false])
            await socket.disconnect()
        }

        @Test func messagesBelowThresholdStayUncompressed() async throws {
            let previous = ConnectionManagerTests.enablePlaintextLoopback()
            defer { ConnectionManagerTests.restorePlaintextLoopback(previous) }
            let server = try await CompressionWebSocketServer.start(mode: .acceptDeflate)
            defer { server.stop() }

            let socket = try await connect(to: server)
            let small = String(repeating: "a", count: PerMessageDeflate.defaultCompressionThreshold - 1)
            let large = String(repeating: "a", count: PerMessageDeflate.defaultCompressionThreshold)
            #expect(try await echo(small, over: socket) == small)
            #expect(try await echo(large, over: socket) == large)
            #expect(server.clientFrameCompression == [false, true])
            await socket.disconnect()
        }

        @Test func unacceptableExtensionResponseFailsTheConnect() async throws {
            let previous = ConnectionManagerTests.enablePlaintextLoopback()
            defer { ConnectionManagerTests.restorePlaintextLoopback(previous) }
            for (header, offers) in [("x-webkit-deflate-frame", true), ("permessage-deflate; bogus", true), ("permessage-deflate", false)] {
                let server = try await CompressionWebSocketServer.start(mode: .respondWith(header))
                defer { server.stop() }
                do {
                    let socket = try await connect(to: server, offersCompression: offers)
                    await socket.disconnect()
                    Issue.record("connect should fail for \(header)")
                } catch let WebSocketTransportError.failed(_, _, failure) {
                    #expect(failure.classification == .malformedResponse, "\(header)")
                }
            }
        }

        @Test func compressedFrameWithoutNegotiationFailsWithProtocolError() async throws {
            let previous = ConnectionManagerTests.enablePlaintextLoopback()
            defer { ConnectionManagerTests.restorePlaintextLoopback(previous) }
            let server = try await CompressionWebSocketServer.start(mode: .compressedFrameWithoutNegotiation)
            defer { server.stop() }

            let socket = try await connect(to: server)
            #expect(socket.negotiatedDeflate == nil)
            #expect(await disconnectCode { _ = try await socket.receive() } == 1002)
        }

        @Test func inflationPastTunnelCapFailsWithMessageTooBig() async throws {
            let previous = ConnectionManagerTests.enablePlaintextLoopback()
            defer { ConnectionManagerTests.restorePlaintextLoopback(previous) }
            let cap = WebSocketConnection.Endpoint.tunnel.maximumMessageSize
            let server = try await CompressionWebSocketServer.start(mode: .inflationBomb(bytes: cap + 1))
            defer { server.stop() }

            let socket = try await connect(to: server, endpoint: .tunnel)
            #expect(socket.negotiatedDeflate != nil)
            #expect(await disconnectCode { _ = try await socket.receive() } == 1009)
        }

        @Test func pingsAndPongsWorkOverCompressedConnection() async throws {
            let previous = ConnectionManagerTests.enablePlaintextLoopback()
            defer { ConnectionManagerTests.restorePlaintextLoopback(previous) }
            let server = try await CompressionWebSocketServer.start(mode: .acceptDeflate)
            defer { server.stop() }

            let socket = try await connect(to: server)
            let receiving = Task { try await socket.receive() }
            try await socket.sendPing()
            let payload = Data([1, 2, 3])
            server.ping(payload)
            let deadline = ContinuousClock.now + .seconds(5)
            while !server.pongs.contains(payload), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(server.pongs.contains(payload))
            receiving.cancel()
            await socket.disconnect()
        }
    }
}

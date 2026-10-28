import Foundation
@testable import Intent
import Testing

/// RFC 6455 §4 opening handshake and RFC 7692 extension negotiation.
struct WebSocketHandshakeTests {
    private static let rfcKey = "dGhlIHNhbXBsZSBub25jZQ=="
    private static let rfcAccept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

    private func response(_ extraHeaders: [String], status: String = "101 Switching Protocols", accept: String = rfcAccept) throws -> WebSocketHandshake.Response {
        let head = (["HTTP/1.1 \(status)", "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Accept: \(accept)"] + extraHeaders)
            .joined(separator: "\r\n") + "\r\n\r\n"
        let parsed = try #require(try WebSocketHandshake.parseResponse(Data(head.utf8)))
        return parsed.response
    }

    private func negotiate(_ extensionHeader: String?, offered: Bool = true) throws -> PerMessageDeflateParameters? {
        let headers = extensionHeader.map { ["Sec-WebSocket-Extensions: \($0)"] } ?? []
        return try WebSocketHandshake.validate(response(headers), key: Self.rfcKey, offeredDeflate: offered)
    }

    @Test func derivesRFCAcceptKey() {
        #expect(WebSocketHandshake.acceptValue(forKey: Self.rfcKey) == Self.rfcAccept)
    }

    @Test func generatesDistinctSixteenByteKeys() throws {
        let first = WebSocketHandshake.makeKey()
        #expect(try #require(Data(base64Encoded: first)).count == 16)
        #expect(first != WebSocketHandshake.makeKey())
    }

    @Test func buildsUpgradeRequestWithAuthAndOffer() throws {
        let url = try #require(URL(string: "wss://daemon.local:4242/ws"))
        let request = WebSocketHandshake.request(
            url: url,
            key: Self.rfcKey,
            headers: WebSocketConnection.additionalHeaders(token: "secret"),
            extensionOffer: PerMessageDeflateParameters.offer
        )
        let text = try #require(String(bytes: request, encoding: .utf8))
        #expect(text.hasPrefix("GET /ws HTTP/1.1\r\nHost: daemon.local:4242\r\n"))
        #expect(text.contains("\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"))
        #expect(text.contains("\r\nSec-WebSocket-Key: \(Self.rfcKey)\r\nSec-WebSocket-Version: 13\r\n"))
        #expect(text.contains("\r\nSec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n"))
        #expect(text.contains("\r\nAuthorization: Bearer secret\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func omitsOfferWhenCompressionIsOff() throws {
        let url = try #require(URL(string: "ws://127.0.0.1:9/tunnel"))
        let request = WebSocketHandshake.request(url: url, key: Self.rfcKey, headers: [], extensionOffer: nil)
        let text = try #require(String(bytes: request, encoding: .utf8))
        #expect(text.hasPrefix("GET /tunnel HTTP/1.1\r\nHost: 127.0.0.1:9\r\n"))
        #expect(!text.contains("Sec-WebSocket-Extensions"))
    }

    @Test func bracketsIPv6HostHeader() throws {
        let url = try WebSocketConnection.makeURL(host: "fd7a:115c::1", port: 4242, certFingerprint: "aa:bb")
        #expect(WebSocketHandshake.hostHeaderValue(for: url) == "[fd7a:115c::1]:4242")
        let zoned = try WebSocketConnection.makeURL(host: "fe80::1%en0", port: 4242, certFingerprint: "aa:bb")
        #expect(WebSocketHandshake.hostHeaderValue(for: zoned) == "[fe80::1%25en0]:4242")
    }

    @Test func nonUTF8ResponseHeadIsMalformedNotOversized() {
        var head = Data("HTTP/1.1 101 Switching Protocols\r\nX-Note: ".utf8)
        head.append(0xFF)
        head.append(contentsOf: Data("\r\n\r\n".utf8))
        #expect(throws: WebSocketHandshakeError.malformedResponse) { try WebSocketHandshake.parseResponse(head) }
    }

    @Test func parsesResponseAndReportsTrailingFrameBytes() throws {
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n"
        var buffer = Data(head.utf8)
        buffer.append(contentsOf: [0x81, 0x00])
        let parsed = try #require(try WebSocketHandshake.parseResponse(buffer))
        #expect(parsed.headerSize == head.utf8.count)
        #expect(parsed.response.statusCode == 101)
        #expect(parsed.response.values("upgrade") == ["websocket"])
    }

    @Test func waitsForCompleteHeadAndCapsItsSize() throws {
        #expect(try WebSocketHandshake.parseResponse(Data("HTTP/1.1 101 Switching\r\nUpgrade: web".utf8)) == nil)
        let oversized = Data(repeating: 0x61, count: WebSocketHandshake.maximumResponseHeaderSize + 1)
        #expect(throws: WebSocketHandshakeError.responseTooLarge) { try WebSocketHandshake.parseResponse(oversized) }
        #expect(throws: WebSocketHandshakeError.malformedResponse) {
            try WebSocketHandshake.parseResponse(Data("garbage\r\n\r\n".utf8))
        }
    }

    @Test func rejectsNonSwitchingStatusAndBadAccept() throws {
        #expect(throws: WebSocketHandshakeError.unexpectedStatus(403)) {
            try WebSocketHandshake.validate(try response([], status: "403 Forbidden"), key: Self.rfcKey, offeredDeflate: true)
        }
        #expect(throws: WebSocketHandshakeError.invalidAccept) {
            try WebSocketHandshake.validate(try response([], accept: "wrong"), key: Self.rfcKey, offeredDeflate: true)
        }
        let noUpgrade = try #require(try WebSocketHandshake.parseResponse(Data("HTTP/1.1 101 OK\r\nConnection: Upgrade\r\n\r\n".utf8)))
        #expect(throws: WebSocketHandshakeError.missingUpgrade) {
            try WebSocketHandshake.validate(noUpgrade.response, key: Self.rfcKey, offeredDeflate: true)
        }
    }

    @Test func absentExtensionMeansUncompressed() throws {
        #expect(try negotiate(nil) == nil)
        #expect(try negotiate(nil, offered: false) == nil)
        #expect(try negotiate("") == nil)
    }

    @Test func acceptsIntentdDefaultAndParameterizedResponses() throws {
        #expect(try negotiate("permessage-deflate") == PerMessageDeflateParameters())
        var expected = PerMessageDeflateParameters()
        expected.serverNoContextTakeover = true
        expected.clientNoContextTakeover = true
        expected.serverMaxWindowBits = 10
        expected.clientMaxWindowBits = 12
        #expect(try negotiate(
            "Permessage-Deflate; server_no_context_takeover; client_no_context_takeover; server_max_window_bits=10; client_max_window_bits=\"12\""
        ) == expected)
    }

    @Test func rejectsUnexpectedOrMalformedExtensions() {
        let invalid = [
            "x-webkit-deflate-frame",
            "permessage-deflate, permessage-deflate",
            "permessage-deflate; unknown_param",
            "permessage-deflate; server_max_window_bits",
            "permessage-deflate; client_max_window_bits",
            "permessage-deflate; server_max_window_bits=16",
            "permessage-deflate; server_max_window_bits=7",
            "permessage-deflate; server_max_window_bits=010",
            "permessage-deflate; server_no_context_takeover=1",
            "permessage-deflate; server_no_context_takeover; server_no_context_takeover",
            "permessage-deflate; =1",
            "permessage-deflate;"
        ]
        for header in invalid {
            #expect(throws: WebSocketHandshakeError.invalidExtensions, "\(header)") { try negotiate(header) }
        }
        // An accepted extension the client never offered (kill switch off).
        #expect(throws: WebSocketHandshakeError.invalidExtensions) { try negotiate("permessage-deflate", offered: false) }
    }
}

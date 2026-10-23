import CryptoKit
import Foundation

/// A server's opening handshake failed RFC 6455 §4.2.2 / RFC 7692 checks.
nonisolated enum WebSocketHandshakeError: Error, Equatable, Sendable {
    case invalidAccept
    case invalidExtensions
    case malformedResponse
    case missingUpgrade
    case responseTooLarge
    case unexpectedStatus(Int)
}

/// The HTTP/1.1 upgrade (RFC 6455 §4.1) the client performs over the raw
/// TLS byte stream, including the permessage-deflate offer and the
/// validation of the server's answer. Pure; the connection supplies bytes.
nonisolated enum WebSocketHandshake {
    typealias Header = (name: String, value: String)
    typealias ExtensionParameter = (name: String, value: String?)

    /// The 101 response headers must fit in this many bytes.
    static let maximumResponseHeaderSize = 16_384
    private static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    private static let keyByteCount = 16
    private static let switchingProtocolsStatus = 101
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// A parsed HTTP response head.
    struct Response: Sendable {
        let statusCode: Int
        let headers: [Header]

        /// All values of a header, in order, with case-insensitive names.
        func values(_ name: String) -> [String] {
            headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
        }
    }

    static func makeKey() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<keyByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
    }

    /// `Sec-WebSocket-Accept` for a key (§4.2.2 step 5.4).
    static func acceptValue(forKey key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + acceptGUID).utf8))).base64EncodedString()
    }

    /// The `Host` header for a ws/wss URL: the authority, with IPv6
    /// literals bracketed and the port always explicit.
    static func hostHeaderValue(for url: URL) -> String {
        let host = url.host(percentEncoded: false) ?? ""
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let port = url.port else { return bracketed }
        return "\(bracketed):\(port)"
    }

    static func request(url: URL, key: String, headers: [Header], extensionOffer: String?) -> Data {
        let path = url.path(percentEncoded: true).isEmpty ? "/" : url.path(percentEncoded: true)
        var lines = [
            "GET \(path) HTTP/1.1",
            "Host: \(hostHeaderValue(for: url))",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13"
        ]
        if let extensionOffer { lines.append("Sec-WebSocket-Extensions: \(extensionOffer)") }
        lines += headers.map { "\($0.name): \($0.value)" }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// Parses the response head once it is fully buffered. Returns nil while
    /// more bytes are needed; `headerSize` counts the bytes consumed, so any
    /// remainder is the first WebSocket frame data.
    static func parseResponse(_ buffer: Data) throws -> (response: Response, headerSize: Int)? {
        guard let terminator = buffer.range(of: headerTerminator) else {
            guard buffer.count <= maximumResponseHeaderSize else { throw WebSocketHandshakeError.responseTooLarge }
            return nil
        }
        let headerSize = terminator.upperBound - buffer.startIndex
        guard headerSize <= maximumResponseHeaderSize,
              let head = String(data: buffer[buffer.startIndex..<terminator.lowerBound], encoding: .utf8) else {
            throw WebSocketHandshakeError.responseTooLarge
        }
        var lines = head.components(separatedBy: "\r\n")
        let statusParts = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."), let status = Int(statusParts[1]) else {
            throw WebSocketHandshakeError.malformedResponse
        }
        let headers = try lines.map { line -> Header in
            guard let colon = line.firstIndex(of: ":") else { throw WebSocketHandshakeError.malformedResponse }
            return (
                name: String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                value: String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            )
        }
        return (Response(statusCode: status, headers: headers), headerSize)
    }

    /// Checks the 101 response (§4.2.2 / §4.1 client requirements) and
    /// returns the agreed permessage-deflate parameters, or nil when the
    /// server did not accept compression.
    static func validate(_ response: Response, key: String, offeredDeflate: Bool) throws -> PerMessageDeflateParameters? {
        guard response.statusCode == switchingProtocolsStatus else {
            throw WebSocketHandshakeError.unexpectedStatus(response.statusCode)
        }
        guard response.values("Upgrade").contains(where: { $0.caseInsensitiveCompare("websocket") == .orderedSame }),
              response.values("Connection").contains(where: { value in
                  value.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("upgrade") == .orderedSame }
              }) else {
            throw WebSocketHandshakeError.missingUpgrade
        }
        guard response.values("Sec-WebSocket-Accept") == [acceptValue(forKey: key)] else {
            throw WebSocketHandshakeError.invalidAccept
        }
        let extensions = try parseExtensions(response.values("Sec-WebSocket-Extensions"))
        guard let accepted = extensions.first else { return nil }
        // Only one extension was offered, so anything else, or more than one
        // answer, is a server the client must fail (§9.1).
        guard offeredDeflate, extensions.count == 1,
              accepted.name.caseInsensitiveCompare(PerMessageDeflateParameters.extensionName) == .orderedSame else {
            throw WebSocketHandshakeError.invalidExtensions
        }
        do {
            return try PerMessageDeflateParameters(responseParameters: accepted.parameters)
        } catch {
            throw WebSocketHandshakeError.invalidExtensions
        }
    }

    /// Splits `Sec-WebSocket-Extensions` values (RFC 7692 §5 grammar):
    /// comma-separated extensions, each `name; param[=value]; ...`, values
    /// optionally quoted.
    static func parseExtensions(_ values: [String]) throws -> [(name: String, parameters: [ExtensionParameter])] {
        try values
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
            .map { element in
                let parts = element.split(separator: ";", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard let name = parts.first, isToken(name) else { throw WebSocketHandshakeError.invalidExtensions }
                let parameters = try parts.dropFirst().map { part -> ExtensionParameter in
                    let pieces = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard let parameterName = pieces.first, isToken(parameterName) else {
                        throw WebSocketHandshakeError.invalidExtensions
                    }
                    guard pieces.count == 2 else { return (parameterName, nil) }
                    var value = pieces[1]
                    if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                        value = String(value.dropFirst().dropLast())
                    }
                    guard isToken(value) else { throw WebSocketHandshakeError.invalidExtensions }
                    return (parameterName, value)
                }
                return (name, parameters)
            }
    }

    private static let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
        .union(CharacterSet(charactersIn: "0123456789"))
        .union(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"))

    private static func isToken(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { tokenCharacters.contains($0) }
    }
}

# 0028. WebSocket transport

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The app speaks JSON-RPC to intentd over its own WebSocket client on Network.framework (RFC 6455), with optional RFC 7692 permessage-deflate. Frames can be large, and a peer can be hostile or broken.

## Decision

1. **Own client on Network.framework.** RFC 6455 handshake and framing and RFC 7692 deflate run in Swift (`WebSocketHandshake`, `WebSocketFrameCodec`, `PerMessageDeflate`), because `NWProtocolWebSocket` aborts any handshake in which the server accepts an extension. URLSession is not used: App Transport Security blocks pinned self-signed wss to non-local hosts. The verify block replaces chain evaluation; the SHA-256 fingerprint is the sole trust decision, and `SecTrustEvaluate` is deliberately not called.
2. **Connection.**
   1. `offersPermessageDeflate` offers deflate on every connection; false restores plain RFC 6455, the rollback path.
   2. The connect deadline is 4 s, the old `URLRequest.timeoutInterval`. It covers TCP, TLS and the upgrade. On timeout the connection is cancelled, because an upgrade child parked in raw I/O ignores task cancellation.
   3. `SocketState` is shared with nonisolated teardown: a close frame is sent only once and only after the upgrade.
   4. Daemon pings get automatic pongs; the app's own liveness pings stay explicit (`sendPing()`). Unsolicited pongs are ignored (RFC 6455 §5.5.3).
   5. A stream that ends without a close frame is an abnormal closure. Protocol violations fail the connection with 1002, 1007 or 1009.
   6. `sendPayload(_:opcode:)` compresses and enqueues before its first suspension, so deflate context order matches wire order.
3. **Diagnostics.** `TransportDiagnosticFailure` classifies at the boundary; it is not a string redactor. Hostnames, fingerprints, foreign descriptions and unknown numeric codes are discarded.
4. **Deflate negotiation.**
   1. The client offer is `permessage-deflate; client_max_window_bits`, the same offer Chromium sends, which intentd accepts. Defaults are the extension's: 15-bit windows with context takeover both ways.
   2. `PerMessageDeflateParameters.init(responseParameters:)` validates the server response against the offer (RFC 7692 §7.1). Unknown, repeated or malformed parameters decline it. `client_max_window_bits` is allowed only because the offer included it, and the response must carry a value (§7.1.2.2).
5. **Deflate codec (`PerMessageDeflate`).**
   1. Compression uses raw deflate with `Z_SYNC_FLUSH` and trims the trailing empty stored block (`00 00 FF FF`); inflation appends it back without copying the payload. Context is kept across messages unless the peer negotiated `*_no_context_takeover`.
   2. It is not thread-safe; the owning `WebSocketConnection` actor serializes use.
   3. Messages below `defaultCompressionThreshold` (1024 bytes) go out uncompressed, like the Node `ws` default the desktop client uses.
   4. zlib cannot produce raw deflate with an 8-bit window (it widens to 9). A peer that limits the client to 8 bits gets uncompressed messages; RSV1 is per message and optional.
   5. A failed deflate can hold part of the payload in its window. The message goes out uncompressed and the deflater is reset, so later messages cannot refer to those bytes.
   6. `decompress(_:maximumSize:)` fails with `.messageTooLarge` as soon as output passes the limit, so a small frame cannot expand past the endpoint cap.
   7. The inflate window is 15 bits, which decodes any smaller window. A final block (BFINAL) ends the stream: the inflater restarts and keeps its window under context takeover, because the server may still refer back. Input left after the stream ends is the sync-flush tail or padding, never more data, and must not reach the restarted stream.

## Code

- `WebSocketConnection`: `offersPermessageDeflate`, `makeParameters(…)`, `awaitOpening(…)`, `SocketState`, `receive()`, `nextInboundEvent()`, `sendPayload(_:opcode:)`, `sendPing()`, `resolvePong(_:)`; `TransportDiagnosticFailure`
- `PerMessageDeflateParameters`: `offer`, `init(responseParameters:)`
- `PerMessageDeflate`: `defaultCompressionThreshold`, `compressIfWorthwhile(_:)`, `compress(_:)`, `decompress(_:maximumSize:)`, `restartInflater(_:)`, `drain(…)`

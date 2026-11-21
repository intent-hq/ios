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
3. **Write ordering and close.**
   1. `write` enqueues synchronously before the caller suspends; it is used for the upgrade request. `writeWhileOpen` refuses once a close frame is queued, so no data follows it (RFC 6455 §5.5.1). `enqueueWhileOpen` holds the lifecycle lock that `close` holds while queuing the close frame, so the two never reorder.
   2. `close(…)` sends a close frame once, only after the socket opened, then cancels the connection. It is safe to call repeatedly from any context. A dead peer can leave the close send pending forever, so a fallback cancel runs after a grace period.
   3. A peer's close is echoed with its own code when that code may be sent, otherwise 1000 (`echoedCloseCode(_:)`). `WebSocketCloseCode.isSendable(_:)` allows the defined codes except 1004, 1005, 1006 and 1015, plus 3000–4999. Network.framework once enforced this; the peer must not send reserved or out-of-range codes.
4. **Framing and handshake.**
   1. Opcodes outside RFC 6455 §5.2 fail the connection. RSV1 is the RFC 7692 compression bit, set only on a message's first frame (§6.1), and meaningful only when deflate was negotiated.
   2. Client frames are always masked (§5.3); a nil key makes an unmasked server frame for test servers. Server frames must be unmasked.
   3. `WebSocketFrameDecoder` checks header rules (reserved bits, masking, control frames, size cap) as soon as the header is buffered, so an oversized frame fails before its payload is buffered.
   4. `MessageAssembler` decodes text only once the message is complete and inflated, so split multi-byte characters stay intact. Buffered and inflated sizes are both capped at `maximumMessageSize`. A continuation without a message in progress is dropped, not turned into a message.
   5. The 101 response head must fit in `maximumResponseHeaderSize` (16 KiB). Only one extension was offered, so any other extension or more than one answer fails the handshake (§9.1). `hostHeaderValue(for:)` brackets IPv6, always includes the port, and keeps the host percent-encoded so an IPv6 zone id is sent as `%25` (RFC 6874).
   6. `WebSocketPingSupport.performPing(pending:send:)` installs the continuation before it sends; the matching pong resumes it, and send errors, timeout and cancellation resume it through `takePending`.
5. **Endpoints and pins.** The `/invite` endpoint is unauthenticated: an empty token sends no header. `allowsPlaintextLoopbackForTesting` is a loopback-only escape hatch for test servers; app code never enables it. `fingerprint(ofCertificate:)` formats SHA-256 as lowercase colon-separated hex, as pairing does, and `fingerprintMatches(_:pinned:)` compares validated bytes across both spellings.
6. **Diagnostics.** `TransportDiagnosticFailure` classifies at the boundary; it is not a string redactor. Hostnames, fingerprints, foreign descriptions and unknown numeric codes are discarded.
7. **Deflate negotiation.**
   1. The client offer is `permessage-deflate; client_max_window_bits`, the same offer Chromium sends, which intentd accepts. Defaults are the extension's: 15-bit windows with context takeover both ways.
   2. `PerMessageDeflateParameters.init(responseParameters:)` validates the server response against the offer (RFC 7692 §7.1). Unknown, repeated or malformed parameters decline it. `client_max_window_bits` is allowed only because the offer included it, and the response must carry a value (§7.1.2.2).
8. **Deflate codec (`PerMessageDeflate`).**
   1. Compression uses raw deflate with `Z_SYNC_FLUSH` and trims the trailing empty stored block (`00 00 FF FF`); inflation appends it back without copying the payload. Context is kept across messages unless the peer negotiated `*_no_context_takeover`.
   2. It is not thread-safe; the owning `WebSocketConnection` actor serializes use.
   3. Messages below `defaultCompressionThreshold` (1024 bytes) go out uncompressed, like the Node `ws` default the desktop client uses.
   4. zlib cannot produce raw deflate with an 8-bit window (it widens to 9). A peer that limits the client to 8 bits gets uncompressed messages; RSV1 is per message and optional.
   5. A failed deflate can hold part of the payload in its window. The message goes out uncompressed and the deflater is reset, so later messages cannot refer to those bytes.
   6. `decompress(_:maximumSize:)` fails with `.messageTooLarge` as soon as output passes the limit, so a small frame cannot expand past the endpoint cap.
   7. The inflate window is 15 bits, which decodes any smaller window. A final block (BFINAL) ends the stream: the inflater restarts and keeps its window under context takeover, because the server may still refer back. Input left after the stream ends is the sync-flush tail or padding, never more data, and must not reach the restarted stream.

## Code

- `WebSocketConnection`: `offersPermessageDeflate`, `makeParameters(…)`, `awaitOpening(…)`, `SocketState`, `receive()`, `nextInboundEvent()`, `sendPayload(_:opcode:)`, `sendPing()`, `resolvePong(_:)`; `TransportDiagnosticFailure`
- `WebSocketConnection` (I/O, security): `write(_:to:host:)`, `writeWhileOpen(…)`, `enqueueWhileOpen(…)`, `close(…)`, `echoedCloseCode(_:)`, `allowsPlaintextLoopbackForTesting`, `additionalHeaders(token:)`, `fingerprint(ofCertificate:)`, `fingerprintMatches(_:pinned:)`
- `WebSocketCloseCode`: `isSendable(_:)`; `WebSocketFrameEncoder`, `WebSocketFrameDecoder`: `nextFrame()`; `MessageAssembler`, `InboundStream`: `nextEvent()`; `WebSocketHandshake`: `maximumResponseHeaderSize`, `hostHeaderValue(for:)`, `validate(_:key:offeredDeflate:)`; `WebSocketPingSupport`: `performPing(pending:send:)`
- `PerMessageDeflateParameters`: `offer`, `init(responseParameters:)`
- `PerMessageDeflate`: `defaultCompressionThreshold`, `compressIfWorthwhile(_:)`, `compress(_:)`, `decompress(_:maximumSize:)`, `restartInflater(_:)`, `drain(…)`

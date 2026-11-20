# 0028. WebSocket transport

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The app speaks JSON-RPC to intentd over its own WebSocket client on Network.framework (RFC 6455), with optional RFC 7692 permessage-deflate. Frames can be large, and a peer can be hostile or broken.

## Decision

1. **Deflate negotiation.**
   1. The client offer is `permessage-deflate; client_max_window_bits`, the same offer Chromium sends, which intentd accepts. Defaults are the extension's: 15-bit windows with context takeover both ways.
   2. `PerMessageDeflateParameters.init(responseParameters:)` validates the server response against the offer (RFC 7692 §7.1). Unknown, repeated or malformed parameters decline it. `client_max_window_bits` is allowed only because the offer included it, and the response must carry a value (§7.1.2.2).
2. **Deflate codec (`PerMessageDeflate`).**
   1. Compression uses raw deflate with `Z_SYNC_FLUSH` and trims the trailing empty stored block (`00 00 FF FF`); inflation appends it back without copying the payload. Context is kept across messages unless the peer negotiated `*_no_context_takeover`.
   2. It is not thread-safe; the owning `WebSocketConnection` actor serializes use.
   3. Messages below `defaultCompressionThreshold` (1024 bytes) go out uncompressed, like the Node `ws` default the desktop client uses.
   4. zlib cannot produce raw deflate with an 8-bit window (it widens to 9). A peer that limits the client to 8 bits gets uncompressed messages; RSV1 is per message and optional.
   5. A failed deflate can hold part of the payload in its window. The message goes out uncompressed and the deflater is reset, so later messages cannot refer to those bytes.
   6. `decompress(_:maximumSize:)` fails with `.messageTooLarge` as soon as output passes the limit, so a small frame cannot expand past the endpoint cap.
   7. The inflate window is 15 bits, which decodes any smaller window. A final block (BFINAL) ends the stream: the inflater restarts and keeps its window under context takeover, because the server may still refer back. Input left after the stream ends is the sync-flush tail or padding, never more data, and must not reach the restarted stream.

## Code

- `PerMessageDeflateParameters`: `offer`, `init(responseParameters:)`
- `PerMessageDeflate`: `defaultCompressionThreshold`, `compressIfWorthwhile(_:)`, `compress(_:)`, `decompress(_:maximumSize:)`, `restartInflater(_:)`, `drain(…)`

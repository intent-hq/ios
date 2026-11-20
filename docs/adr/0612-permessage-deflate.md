# ADR-0612: permessage-deflate (RFC 7692) codec

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `PerMessageDeflateParameters`, `PerMessageDeflate` (`Intent/Services/PerMessageDeflate.swift`)

## Context

The WebSocket transport negotiates RFC 7692 permessage-deflate. `PerMessageDeflate`
is the zlib-backed codec for one connection.

## Decisions

### 1. Negotiation

Applies to: `PerMessageDeflateParameters`

1. The parameter defaults are the extension's defaults: 15-bit windows with
   context takeover both ways.
2. `offer` is the same offer that Chromium sends, which intentd accepts.
3. `init(responseParameters:)` validates a server response (RFC 7692 §7.1)
   against `offer`. Unknown, repeated, or malformed parameters decline the
   response.
4. `client_max_window_bits` in a response is allowed only because the offer
   included it, and the response must carry a value (§7.1.2.2).

### 2. Framing

Applies to: `PerMessageDeflate`

1. Compression uses raw deflate with `Z_SYNC_FLUSH` and trims the trailing
   empty stored block (0x00 0x00 0xFF 0xFF). Inflation appends it back.
2. Context is kept across messages unless the peer negotiated
   `*_no_context_takeover`.
3. The codec is not thread-safe. The owning `WebSocketConnection` actor
   serializes use.

### 3. Compression rules

Applies to: `PerMessageDeflate.defaultCompressionThreshold`,
`PerMessageDeflate.smallestDeflatableWindow`, `PerMessageDeflate.compressIfWorthwhile(_:)`,
`PerMessageDeflate.compress(_:)`

1. Outbound messages smaller than 1024 bytes are sent uncompressed (RSV1
   clear). This matches the Node `ws` default that the desktop client uses.
2. zlib cannot produce raw deflate with an 8-bit window; it silently widens to
   9. So a peer that limits the client to 8 bits gets uncompressed messages
   instead. RSV1 is per message and optional.
3. `compressIfWorthwhile` returns the payload to send with RSV1 set, or nil
   when the message goes out uncompressed (below the threshold, or deflate
   disabled).
4. `compress` deflates one whole message payload (RFC 7692 §7.2.1).
5. A failed deflate may already hold part of the payload in its window. The
   message goes out uncompressed, so the peer never sees those bytes. The
   deflater is reset so later messages cannot refer to them.

### 4. Decompression rules

Applies to: `PerMessageDeflate.decompress(_:maximumSize:)`,
`PerMessageDeflate.restartInflater(_:)`, `PerMessageDeflate.drain(...)`

1. The inflater uses a 15-bit window, which decodes streams from any smaller
   window. `maximumWindowSize` is the largest LZ77 window (2^15 bytes, RFC 1951
   §2).
2. `decompress` fails with `.messageTooLarge` as soon as the output would
   exceed `maximumSize`, so a small compressed frame cannot expand past the
   endpoint cap.
3. The payload is inflated first, then the sync-flush tail that the sender
   stripped (RFC 7692 §7.2.2), without copying the payload to append it. After
   a final block, the tail must not reach the restarted stream.
4. A final block (BFINAL, §7.2.3.4) ends the DEFLATE stream, and the next
   message starts a new one. `streamEnded` records this for the current
   message. The inflater restarts and keeps the LZ77 window when context
   takeover is in effect, because the server may still refer back to earlier
   messages.
5. `drain` runs the zlib step until all input is consumed and zlib stops
   filling the output chunk. It returns false on a zlib error or when the limit
   is hit. `Z_BUF_ERROR` means no progress is possible: all input consumed and
   output flushed. After `Z_STREAM_END`, any input left in the message is the
   appended sync-flush tail or padding, never more data.

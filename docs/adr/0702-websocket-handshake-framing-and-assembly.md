# ADR-0702: WebSocket handshake, framing, and message assembly follow RFC 6455 and RFC 7692

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WebSocketHandshake`, `WebSocketHandshakeError` (`Intent/Services/WebSocketHandshake.swift`),
  `WebSocketOpcode`, `WebSocketFrame`, `WebSocketProtocolViolation`, `WebSocketCloseCode`,
  `WebSocketFrameLayout`, `WebSocketMaskingKey`, `WebSocketFrameEncoder`, `WebSocketFrameDecoder`
  (`Intent/Services/WebSocketFrameCodec.swift`),
  `WebSocketConnection.MessageAssembler`, `WebSocketConnection.InboundStream`
  (`Intent/Services/WebSocketMessageAssembler.swift`),
  `WebSocketConnection.Upgrade` (`Intent/Services/WebSocketConnectionIO.swift`)

## Context

ADR-0701 moved the WebSocket protocol into Swift. These types implement the
HTTP upgrade, the frame format, and message reassembly. They are pure: the
connection supplies bytes and acts on the results.

## Decisions

### 1. The handshake is a pure HTTP/1.1 upgrade

Applies to: `WebSocketHandshake`, `WebSocketHandshakeError`, `WebSocketConnection.Upgrade`

`WebSocketHandshake` is the HTTP/1.1 upgrade (RFC 6455 §4.1) that the client
performs over the raw TLS byte stream. It includes the permessage-deflate offer
and the validation of the server's answer. `WebSocketHandshakeError` means the
server's opening handshake failed the RFC 6455 §4.2.2 or RFC 7692 checks.

`acceptValue(forKey:)` is the `Sec-WebSocket-Accept` value for a key (§4.2.2
step 5.4).

`hostHeaderValue(for:)` builds the `Host` header from the URL authority: IPv6
literals are bracketed and the port is always explicit. The host stays
percent-encoded, so an IPv6 zone ID is sent as `%25` (RFC 6874).

`parseResponse` returns nil while more bytes are needed. `headerSize` counts the
bytes consumed, so any remainder is the first WebSocket frame data. That
remainder is `Upgrade.leftover`: frame bytes that arrived with the 101.
`Upgrade.deflate` is nil when the connection is uncompressed.

`validate` checks the 101 response against the §4.2.2 and §4.1 client
requirements. It returns the agreed permessage-deflate parameters, or nil when
the server did not accept compression. Only one extension is offered, so any
other extension, or more than one answer, is a server the client must fail
(§9.1).

`parseExtensions` splits `Sec-WebSocket-Extensions` values with the RFC 7692 §5
grammar: comma-separated extensions, each `name; param[=value]; ...`, with
values optionally quoted.

### 2. Frame format

Applies to: `WebSocketOpcode`, `WebSocketFrame`, `WebSocketFrameLayout`, `WebSocketMaskingKey`,
`WebSocketFrameEncoder`

`WebSocketOpcode` holds the RFC 6455 §5.2 opcodes. Values outside this set fail
the connection. Control opcodes have the high bit of the opcode nibble set
(§5.5). `WebSocketFrameLayout` is the bit layout of the §5.2 base framing
protocol.

`WebSocketFrame.isCompressed` is the RSV1 bit, which RFC 7692 assigns to
permessage-deflate. It is set on the first frame of a compressed message only
(RFC 7692 §6.1), so `InboundStream` rejects a compressed continuation frame.

`WebSocketMaskingKey` is the 4-byte client masking key (§5.3). Callers of
`init(bytes:)` pass exactly `maskingKeySize` bytes read from a frame header.
`apply(to:)` XORs the buffer with the repeating key; masking and unmasking are
the same operation. The fast path repeats the key across a 64-bit word. The
word size is a multiple of the key size, so the key phase stays aligned with
the offset.

`WebSocketFrameEncoder` always masks client frames (§5.3). A nil key produces an
unmasked server frame, which test servers use.

### 3. The decoder checks headers before buffering a payload

Applies to: `WebSocketFrameDecoder`

The decoder is incremental: append bytes as they arrive and pull complete
frames. Header checks (reserved bits, masking, control frame rules, and the
frame size cap) run as soon as the header is buffered, so an oversized frame
fails before any of its payload is buffered.

`Role` says which side decodes. Server frames must be unmasked and client frames
must be masked (§5.1). `allowsCompressedFrames` says whether RSV1 is meaningful,
which is when permessage-deflate is negotiated.

`nextFrame` returns nil when more bytes are needed and throws when the buffered
header violates the protocol. `validatedOpcode` checks the first two header
bytes against the §5.2 and §5.5 rules. `readPayloadLength` returns the payload
length and the header size up to the masking key, or nil while the extended
length bytes are not yet buffered.

### 4. Violations map to RFC close codes

Applies to: `WebSocketProtocolViolation`, `WebSocketCloseCode`

`WebSocketProtocolViolation` lists peer behaviour that RFC 6455 or RFC 7692
requires the endpoint to fail the connection for. `closeCode` is the RFC 6455
§7.4.1 status code sent in the close frame. `WebSocketCloseCode` holds the
§7.4.1 codes the client sends or interprets.

`WebSocketCloseCode.isSendable` says whether a code may appear in a close frame
on the wire: the defined protocol codes (excluding 1004 and the local-only
1005, 1006, and 1015) and the registered and private ranges 3000–4999.
`InboundStream` rejects a peer close frame with a reserved or out-of-range code
(RFC 6455 §7.4.1, §7.4.2). Network.framework used to enforce this check.

### 5. Messages are decoded and inflated only when complete

Applies to: `WebSocketConnection.MessageAssembler`, `WebSocketConnection.InboundStream`

`MessageAssembler` reassembles fragmented messages. It is pure and unit-testable.
Text is UTF-8-decoded only once the message is complete and inflated, so
multi-byte characters split across fragments stay intact. A message whose first
frame had RSV1 set is inflated with the negotiated permessage-deflate context
after reassembly. Both the buffered size and the inflated size are capped at
`maximumMessageSize`.

A continuation with no message in progress is a protocol violation.
`MessageAssembler` drops it and records a failure rather than fabricate a
message.

`InboundStream` turns raw socket bytes into messages and control events: frame
decoding, RFC 6455 fragmentation rules, and permessage-deflate. It is pure; the
connection feeds bytes and acts on events (pong replies, close). `nextEvent`
returns nil when more bytes are needed and throws a `MessageAssemblyError` when
the peer must be failed.

# ADR-0701: WebSocket transport runs on Network.framework with certificate pinning

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WebSocketConnection` (`Intent/Services/WebSocketConnection.swift`),
  `WebSocketConnection` I/O extension (`Intent/Services/WebSocketConnectionIO.swift`),
  `WebSocketConnection.Endpoint` and pinning helpers (`Intent/Services/WebSocketConnectionSecurity.swift`),
  `WebSocketTransportError`, `HostCertMismatch` (`Intent/Services/WebSocketTransportError.swift`),
  `WebSocketPingSupport` (`Intent/Services/WebSocketPingSupport.swift`)

## Context

The app talks to the daemon over a WebSocket. The daemon uses a self-signed
certificate, and the app trusts it only through a SHA-256 fingerprint saved at
pairing. The transport must also support permessage-deflate compression.

## Decisions

### 1. WebSocket runs in Swift over a Network.framework TLS byte stream

Applies to: `WebSocketConnection`

The RFC 6455 handshake and framing, and RFC 7692 permessage-deflate, run in
Swift (`WebSocketHandshake`, `WebSocketFrameCodec`, `PerMessageDeflate`).
`NWProtocolWebSocket` is not used because it aborts any handshake in which the
server accepts an extension, so it cannot compress.

URLSession is deliberately not used. App Transport Security applies to
URLSession connections and blocks pinned self-signed wss connections to
non-local hosts (public IPs, Tailscale). Network.framework leaves trust to the
TLS verify block.

### 2. The certificate fingerprint is the sole trust decision

Applies to: `WebSocketConnection.makeParameters`, `WebSocketConnection.fingerprint(ofCertificate:)`,
`WebSocketConnection.fingerprintMatches(_:pinned:)`

The verify block replaces default chain evaluation entirely, because the
daemon's certificate is self-signed. `SecTrustEvaluate` is deliberately not
called.

`fingerprint(ofCertificate:)` returns the SHA-256 of the DER certificate as
lowercase colon-separated hex. That is the normalization the pairing flow uses.
`fingerprintMatches` compares the validated SHA-256 bytes, so both supported
spellings of a fingerprint match.

### 3. A record without a pin is refused before a token is sent

Applies to: `WebSocketTransportError.missingCertificatePin`, `WebSocketConnection.transportScheme`

When the record has no trusted certificate pin, the connection is refused
before any bearer token can be sent over a socket.

`WebSocketConnection.allowsPlaintextLoopbackForTesting` exists only in Debug.
It is the plaintext escape hatch for loopback-only test servers. App code never
enables it.

### 4. The invite endpoint is unauthenticated

Applies to: `WebSocketConnection.Endpoint.invite`, `WebSocketConnection.additionalHeaders(token:)`

`/invite` is the host's unauthenticated invite-join endpoint. Its callers hold
no credential, so an empty token sends no `Authorization` header.

### 5. Host races report every certificate mismatch

Applies to: `WebSocketTransportError.certificateMismatches`, `HostCertMismatch`,
`WebSocketTransportError.relabeled(host:)`

`HostCertMismatch` is one observed per-host mismatch: the candidate host and the
fingerprint it actually presented, as opposed to the pinned one. When a host
race finds no winner and at least one candidate presented a wrong certificate,
`certificateMismatches` carries every observed mismatch instead of only the
last one.

`relabeled(host:)` changes a single-route error's host label without changing
its failure details. Aggregate mismatches keep each candidate's original host.

### 6. Connect timeout and compression defaults

Applies to: `WebSocketConnection.connectTimeoutSeconds`, `WebSocketConnection.offersPermessageDeflate`,
`WebSocketConnection.negotiatedDeflate`, `WebSocketConnection.connect`

The connect deadline is 4 seconds. It matches the `URLRequest.timeoutInterval`
that the earlier URLSession-based transport used, and it covers TCP, TLS, and
the HTTP upgrade.

`offersPermessageDeflate` offers compression on every connection. Setting it to
false restores a plain RFC 6455 connection with no extension header. That is
the rollback path for compression, and `connect`'s `offersCompression`
parameter defaults to this kill switch.

`negotiatedDeflate` is the extension the server accepted. It exists for logs
and tests, and is nil when the connection is uncompressed.

### 7. If opening fails, the connection is cancelled

Applies to: `WebSocketConnection.awaitOpening`

The upgrade child task may be parked in a raw read or write, which ignores task
cancellation, and a task group waits for every child before it returns. On any
failure, including the timeout, the code cancels the `NWConnection`. That
completes the parked I/O, so the timeout is honoured.

The state handler that `configureStateHandler` installs keeps lifecycle events
in order and keeps typed failure provenance (`TransportDiagnosticFailure`).

### 8. A close frame is sent once, and no data follows it

Applies to: `WebSocketConnection.SocketState`, `WebSocketConnection.enqueueWhileOpen`,
`WebSocketConnection.writeWhileOpen`, `WebSocketConnection.close`

The socket lifecycle is shared with nonisolated teardown paths. A close frame
is sent only once, and only after the upgrade completed.

`enqueueWhileOpen` enqueues while it holds the lifecycle lock. `close` holds the
same lock while it queues the close frame, so the two can never reorder.
`enqueueWhileOpen` returns false once the socket is closing. `writeWhileOpen`
is `write` for frames after the upgrade: it refuses once a close frame is
queued, so no data follows it on the wire (RFC 6455 §5.5.1).

`close` is safe to call repeatedly and from any context. Once the connection is
cancelled, further sends complete with an error and `cancel()` is idempotent.
When the state is already `closing`, a close frame is in flight with its
fallback cancel. An unresponsive peer or a dead path can leave the close-frame
send pending forever, so `close` always schedules a fallback cancel after
`Constants.WebSocket.closeCancellationGracePeriod`.

`echoedCloseCode` answers a peer's close with the peer's code when that code may
be sent on the wire, and otherwise with 1000 (RFC 6455 §5.5.1).

### 9. Write ordering

Applies to: `WebSocketConnection.write`, `WebSocketConnection.sendPayload`, `WebSocketConnection.read`

`write` enqueues synchronously, before the caller suspends, and then waits until
Network.framework has processed the data. It is used for the upgrade request,
before the socket is open.

`sendPayload` compresses (when deflate is negotiated and worthwhile) and writes
one unfragmented message. Compression and the enqueue happen before the first
suspension, so the deflate context order always matches the wire order.

`read` returns the next available bytes, and nil when the peer ended the stream.
When the stream ends without a close frame, `receive` reports an RFC 6455
abnormal closure (1006).

### 10. Pings and pongs

Applies to: `WebSocketConnection.receive`, `WebSocketConnection.resolvePong`,
`WebSocketPingSupport.performPing`

The connection replies to daemon pings automatically. The app's own liveness
pings stay explicit through `sendPing()`.

`performPing` installs the continuation that `sendPing()` waits on, then runs
`send`, which writes the ping frame. The receive path resumes the continuation
when the matching pong arrives. Send errors, the ping timeout, and cancellation
resume it through `takePending`. Unsolicited pongs are ignored (RFC 6455
§5.5.3).

### 11. Protocol violations close with a matching code

Applies to: `WebSocketConnection.nextInboundEvent`

A protocol violation in the inbound stream fails the connection with the
matching close code: 1002, 1007, or 1009.

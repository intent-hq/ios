# ADR-0057: The browser tunnel forwards only daemon-loopback traffic over its own wire format

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `BrowserTunnelProxy` (`Intent/Services/BrowserTunnelProxy.swift`),
  `BrowserTunnelRelay` (`Intent/Services/BrowserTunnelRelay.swift`),
  `BrowserTunnelFlow` (`Intent/Services/BrowserTunnelFlow.swift`),
  `BrowserTunnelFrame` (`Intent/Services/BrowserTunnelFrame.swift`),
  `BrowserTunnelListener`, `BrowserTunnelTCP` (`Intent/Services/BrowserTunnelListener.swift`),
  `BrowserTunnelURL` (`Intent/Services/BrowserTunnelURL.swift`)

## Context

The in-app browser reaches daemon-local web servers through a tunnel. A local
listener accepts browser connections and multiplexes them over one
authenticated WebSocket to the daemon's `/tunnel` endpoint.

## Decisions

### 1. The `/tunnel` wire format is separate from JSON-RPC

Applies to: `BrowserTunnelFrame`, `BrowserTunnelFrame.init(decoding:)`

The format is independent of JSON-RPC (protocol §1.4). Decoding validates
exhaustively against the protocol opcode table.

### 2. Only explicit daemon-loopback names are forwarded

Applies to: `BrowserTunnelURL.remotePort(for:localPorts:)`

Arbitrary DNS names never gain access to the tunnel. No daemon bearer token
appears in the browser URL. Only the exact address that `rewrite` emits
(`127.0.0.1` on a local listener port) is our own listener. A
`daemon.localhost` URL on the same numeric port still names the daemon.

### 3. The listener binds IPv4 loopback only

Applies to: `BrowserTunnelListener`

It binds `127.0.0.1` explicitly, never an unspecified or all-interface address.

### 4. Network callbacks stay off the main actor

Applies to: `BrowserTunnelTCP`

Network callbacks run off `MainActor` and pass only `Sendable` values.

### 5. One browser owns one tunnel, and streams drain separately

Applies to: `BrowserTunnelProxy`, `BrowserTunnelWebSocket`

One browser owns one authenticated tunnel and a bounded set of local ports.
Receive never waits for a downstream TCP write; each stream drains on its own.
`BrowserTunnelWebSocket` is an injectable wire seam. Production uses the
existing pinned `WebSocketConnection` actor.

### 6. Stream IDs are never reused

Applies to: `BrowserTunnelProxy.accept(_:port:)`

Stale callbacks and final CLOSE frames therefore cannot affect a replacement
stream. Reopening the browser resets the ID space.

### 7. Flow control credit follows delivery

Applies to: `BrowserTunnelFlow`, `BrowserTunnelRelay.receiveData(_:stream:)`

Per-stream bookkeeping includes the write currently in flight. Credit is
returned by `delivered()`, never when a DATA frame is only received. Empty
payloads carry no application data and no credit.

### 8. Close drains received data first

Applies to: `BrowserTunnelRelay.receiveClose(_:stream:)`, `BrowserTunnelRelay.takeDownstream(_:)`

DATA already received is drained before the local socket closes. When the
CLOSE frame is reached, EOF has already flushed a write-side FIN. Closing is
then safe, because all earlier `contentProcessed` callbacks completed in order.

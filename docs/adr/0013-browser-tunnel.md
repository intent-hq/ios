# 0013. Browser tunnel

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The in-app browser reaches dev servers on the daemon host through the `/tunnel` WebSocket (protocol §1.4). The app listens on local ports and forwards TCP streams.

## Decision

1. **Security.**
   1. `BrowserTunnelListener` binds IPv4 loopback only, never an all-interface address.
   2. `BrowserTunnelURL` forwards only explicit daemon-loopback names. Arbitrary DNS names never reach the tunnel. No daemon bearer token appears in a browser URL.
   3. Only the exact `127.0.0.1` address that `rewrite` emits names our listener. A `daemon.localhost` URL on the same port still names the daemon.
   4. One browser owns one authenticated tunnel and a bounded set of local ports. Production uses the pinned WebSocket connection.
2. **Wire.** `BrowserTunnelFrame` is independent of JSON-RPC. Decoding validates every opcode in the protocol table.
3. **Flow control.**
   1. Receive never waits for a downstream TCP write. Each stream drains separately.
   2. `BrowserTunnelFlow` tracks the write in flight. Credit returns at `delivered(_:)`, never when a DATA frame is only received. Empty payloads carry no data or credit.
4. **Stream lifetime.**
   1. Stream ids are never reused, so stale callbacks and late CLOSE frames cannot affect a new stream. Reopening the browser resets the id space.
   2. On remote close, DATA already received drains before the local socket closes.
   3. After EOF has flushed a write-side FIN, the stream can close, because all earlier `contentProcessed` callbacks completed in order.
5. **Isolation.** Network callbacks stay off the main actor and pass only `Sendable` values (`BrowserTunnelTCP`).

## Consequences

- A page cannot reach arbitrary hosts through the tunnel.

## Code

- `BrowserTunnelListener`, `BrowserTunnelTCP`, `BrowserTunnelURL`: `rewrite(_:localPort:)`, `BrowserTunnelFrame`: `init(decoding:)`, `BrowserTunnelFlow`, `BrowserTunnelProxy`: `accept(_:port:)`, `removeStream(_:notifyDaemon:)`, `BrowserTunnelWebSocket`

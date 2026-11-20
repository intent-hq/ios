# ADR-0620: Tailcat tunnel dialing and teardown

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `TunnelSession`, `TunnelDialing`, `UnavailableTunnelDialer`, `TunnelClientHandle`, `TailcatTunnelSession`, `TailcatTunnelDialer`, `TailcatTunnelDialer.DialHandle` (`Intent/Services/TailcatTunnel.swift`)

## Context

A tailcat tunnel session is a loopback forwarder that pipes
`127.0.0.1:localPort` to the daemon's WSS port over the tunnel.
`TailcatTunnelDialer` is the real dialer over the vendored
`TailcatKit.xcframework`, built with gomobile.

## Decisions

### 1. Seams for tests

Applies to: `TunnelDialing`, `TunnelClientHandle`, `TunnelForwarderHandle`

1. `TunnelDialing` is abstracted so the `ConnectionManager` race can be tested
   with a faked framework. `open(tcAddress:remotePort:)` establishes the
   tunnel and starts a loopback forwarder piping to `remotePort` on the
   daemon.
2. `TunnelClientHandle` and `TunnelForwarderHandle` are the gomobile handles a
   session tears down. They are abstracted so teardown can be tested with
   injected (blocking) fakes; the TailcatKit projections conform.

### 2. Platforms without TailcatKit fail fast

Applies to: `UnavailableTunnelDialer`

visionOS has no TailcatKit build: gomobile has no xros slice (see
`TailcatKit/build_xcframework.sh`). `UnavailableTunnelDialer` fails every dial
fast with a clear error, so a tunnel candidate degrades gracefully instead of
crashing. It is compiled on every platform for test visibility.

### 3. Session teardown is exactly once and off the caller's executor

Applies to: `TailcatTunnelSession.init(client:forwarder:)`, `TailcatTunnelSession.close()`,
`TailcatTunnelSession.markClosed()`

1. The session owns the gomobile client and its loopback forwarder.
   `forwarder` is nil for a partially constructed session (client dialed, no
   forwarder started). Its `localPort` is then 0, and `close()` tears down only
   the client.
2. `close()` runs exactly once: the first caller tears down and awaits it, and
   later callers return at once.
3. The gomobile closes run off the caller's executor. `close()` takes the Go
   startup mutex and can block for seconds, which on a cooperative executor (or
   the main actor) would park that thread for the whole time.
4. The continuation is deliberately not cancellation-aware. A cancelled caller
   must still release the handles, so teardown always completes.
5. The background close captures `self` (lock-guarded) instead of the
   non-Sendable gomobile handles.
6. `markClosed()` is synchronous because `NSLock.lock()` is unavailable from
   asynchronous contexts.

### 4. Establishment timeout

Applies to: `TailcatTunnelDialer.establishTimeoutMs`

The 20 s bound covers tunnel establishment (the warm-up ping), including
first-use DERP discovery and a relay round-trip. It is deliberately much
longer than `WebSocketConnection.connectTimeout`: the tunnel is the slow-path
candidate and only needs to finish, not finish fast. Reachable direct hosts win
the race long before this.

### 5. Cancellation bridges to the blocking gomobile dial

Applies to: `TailcatTunnelDialer.DialHandle`, `TailcatTunnelDialer.open(tcAddress:remotePort:)`

1. `DialHandle` bridges task cancellation to the blocking gomobile dial.
   `cancel()` records the cancellation and closes the in-flight client, so a
   blocked `ping` is torn down instead of left running unowned. It is internal
   for test visibility.
2. The close runs off the cancelling thread. gomobile `close()` takes the same
   Go mutex that first-use startup (DERP map fetch, engine start) holds for its
   whole duration, so a synchronous close inside a cancellation handler would
   block whoever called `Task.cancel()`, possibly the main actor, until startup
   finished.
3. `register(_:)` returns false when the dial was already cancelled; the caller
   must close the client and stop. Before registration, the dial thread closes
   the client itself when `register` fails.
4. `cancelledAt` is when `cancel()` first ran, or nil while the dial is still
   wanted. `cancel()` is idempotent: only the first call records the time and
   closes.
5. The background close captures `self` (lock-guarded) instead of the
   non-Sendable gomobile client. `client` is never unset once registered.

### 6. What the gomobile close can and cannot interrupt

Applies to: `TailcatTunnelDialer.DialHandle.cancel()`

For the tailcat `Client`:

1. Before first use, `Close()` is a no-op (nothing is started yet). A cancel
   that lands between `register` and the ping's startup closes nothing, and the
   stack still starts afterwards. The dial thread checks `isCancelled` again
   once `ping` returns and tears down itself.
2. During startup, `Close()` blocks on the startup mutex and closes only once
   startup finished. It cannot abort a DERP map fetch in flight.
3. During the meow wait, `Close()` closes the engine but does not wake the
   wait, which runs to its own internal 10 s cap.

Cancellation therefore never shortens `ping`; it only guarantees teardown.
`raceCandidates` no longer waits on losers, so this cost is off the connect
critical path. The debug log lines measure it.

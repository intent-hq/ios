# 0018. Connection routes, host racing and recovery

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

A saved daemon has several host routes and can have a Tailcat tunnel address. `ConnectionManager` races routes, recovers lost sockets, refreshes routes after connect, and sends JSON-RPC requests.

## Decision

1. **Transport security.** `connect()` fails closed before it touches state or opens a socket when `WebSocketConnection.trustedPin(_:)` has no pin. A pinless saved record must never send its bearer over plaintext. A manual `retryConnection()` skips backoff but never replaces a connected socket or an initial attempt. Pin failures still need the pairing flow.
2. **Host racing (`raceCandidates`).**
   1. One connect attempt runs per host. The race settles on the first success without waiting for losers. A background drain (`HostRaceOutcome.drain`) cancels the losers, disconnects late successes, and reports late certificate mismatches.
   2. Candidates run as unstructured tasks and report into `RaceMailbox`. A task group cannot return before every child ends, so a slow loser would stall the connect. Unlike `AsyncStream`, the mailbox still delivers after the consumer is cancelled, so cleanup drains every candidate.
   3. Mismatches seen before settling stay on the outcome; a winner does not swallow a loser's mismatch. With no winner, every candidate is awaited, and an aggregate certificate error wins over generic failures.
   4. Cancelling losers runs their cancellation handlers synchronously on the settling thread. Handlers must not block. The tunnel dial's `DialHandle.cancel()` closes off-thread for this reason.
   5. After a winner, only a concrete late pin rejection counts. Generic cancellation fallout of a loser is not another failure.
   6. The caller gets the drain (`WonHostRace`) because only it knows the connection generation. `recordLateCertMismatches(…)` drops them if a newer `connect()` or `disconnect()` moved `connectionGeneration`.
3. **Certificate mismatches.** `certMismatches` keeps the latest fingerprint per host. It accumulates across reconnects. `teardownConnection()` keeps it; an explicit `disconnect()` clears it. `resetCertMismatchesIfTargetChanged(…)` clears it when a new `connect()` targets another backend: with a pin, port and pin identify the daemon (host lists drift); without one, host overlap decides.
4. **Overlapping connects.** Pairing over a live connection does not tear down first, so overlapping attempts share a generation. `connectAttempt` makes the newest attempt win adoption, whichever finishes first.
5. **Tailcat tunnel.**
   1. The tunnel races under `tunnelCandidateLabel`, which is not a dialable name. Loopback transport errors are relabelled to it, so the user sees a known route and a mismatch never collides with a real `127.0.0.1` host.
   2. `connectViaTunnel(…)` establishes the tunnel (with its slow first-use warm-up) and then runs the normal pinned WSS handshake through the loopback forwarder. It closes the tunnel on any later failure, so a lost race never leaks a session. `RacedConnection.disconnect()` tears down both.
   3. A tunnel's local socket cannot see its remote underlay. Path monitoring applies to tunnels only. Direct sockets, including system VPNs, use only endpoint evidence (`readSocketPath`). Preference or virtual-interface changes alone do not invalidate a serving tunnel.
   4. `makePathMonitor` makes a fresh monitor per live socket, because `NWPathMonitor` is one-shot.
6. **Startup admission.** Every initial connection and recovery goes through `readyRace(…)`. Racing only opens a transport; normal subscriptions cannot see a bootstrap seat. A new attempt id or an unknown schema replaces the whole startup snapshot, dropping counters and ETA. A failed startup keeps its state so Retry stays. The process lifecycle, not one iPad window, owns suspension, so one background scene cannot stop another window's session.
7. **Route refresh after connect.**
   1. `scheduleHostRoutesRefresh()` is fire-and-forget on every successful connect, so it never delays use.
   2. `refreshHostRoutes()` reads `system.status` `localIps` and merges them into the in-memory hosts and the stored record. Failures are non-fatal. The display-name refresh runs first, even when the `localIps` part bails out.
   3. It persists to the record that the live connection used, matched by token and port (`savedConnection(token:port:)`) and updated by record id. `upsertConnection` matches by host set and port and would duplicate a growing record. During pairing the active record is still the old one until `ConnectionPairing.finalize` saves and reconnects.
   4. It merges against the stored hosts, not only the in-memory list, so a narrower session host list cannot drop stored hosts.
   5. `mergeHosts(existing:reported:)` keeps existing hosts and their order and appends new ones, deduplicated case-insensitively (ios#341). Reported values are untrusted: they must be valid URL hosts, and raw IPv6 literals are bracketed before racing or persisting.
   6. `refreshStoredDisplayName(…)` uses `host.status` (prettyHostname → hostname → keep), so old records heal. A reconnect, credential import or route edit can supersede the reply (`hostRefreshIsCurrent(_:)`).
   7. `updateCachedCredentials(…)` adopts registry-merged fields for the active connection and keeps the live socket. The daemon checks the token only at the WebSocket upgrade.
8. **Requests.**
   1. `defaultRequestTimeout` is 10 s. A long daemon operation (for example `workspace.create`) passes a timeout above the daemon's own budget, so the daemon's structured result wins over a client timeout, like FE `timeoutMs`.
   2. `awaitResponse(…)` resumes the continuation exactly once. Whoever removes the entry from `pendingRequests` on the main actor owns the resume: a reply, `failAllPending`, or the timeout task. A silent daemon still gets a timeout, because a suspended continuation does not see task cancellation.
9. **Heartbeat.** `startHeartbeat()` sleeps one interval, then probes. Probes are sequential and guarded by generation and socket, so a retired result is ignored.
10. **In-process transport.** `ConnectionRequestTransport` stands in for the socket: it answers every request and supplies identity and capabilities. `makeInProcessTransport(…)` is the single Debug seam; Release has no demo types and always uses the socket. Readiness then follows the connection state directly.
11. **Added from test comments.**
    1. A socket that lived at least `stableConnectionThreshold` (10 s) restarts recovery at the first attempt, with no backoff. A shorter-lived socket continues the backoff from its previous attempt (`reconnectStartingAttempt(connectionLifetime:previousAttempt:)`).
    2. A pairing that fails while the manager is reconnecting keeps the reconnect loop and its original target. It never leaves the app on `.connecting` for the failed target (monorepo#4185).
    3. Platforms without a TailcatKit build (visionOS) use `UnavailableTunnelDialer`. A tunnel candidate then fails with a clear unavailable error under the tunnel label; it does not crash.
    4. `WebSocketMessageAssembler.MessageAssembler` decodes text only from a complete message. A multi-byte UTF-8 character split across fragments must not be decoded early. A malformed message does not affect the next one.
    5. Path classification uses interface metadata, never name prefixes.
11. **Network availability.** `NetworkAvailability` is presentation-only default-path evidence, independent of socket and retry ownership. Neither a satisfied nor an unsatisfied general path proves an endpoint is reachable. It is shared across windows, never with `ConnectionManager`'s per-socket monitor. Each foreground scene holds one lease (`acquire()`), including during startup and reconnection; it is released on background or teardown, not on socket loss. After the last release, the next acquire waits for a fresh real path callback.
12. **Path snapshots.** `NetworkPathSnapshot.unsatisfiedReason` matters only for an unsatisfied path and does not diagnose Airplane Mode. `isSatisfied` keeps the transport's existing satisfied interpretation. `physicalInterfaces` keeps `NWPath` preference order, even under a virtual primary.
13. **Socket path evidence.** `SocketPathObservation` captures connection-queue evidence before adoption without actor-hop ordering races. A general `NWPathMonitor` describes default routing, not this endpoint's reachability. `ready(path:)` replaces setup-time evidence; `observe(_:)` installs then replays, and notifications read current state.
14. **Tailcat sessions.**
   1. `TailcatTunnelSession` owns the gomobile client and loopback forwarder. It is `@unchecked Sendable` because the gomobile projections are thread-safe Go handles and `closed` is lock-guarded. A partly built session (no forwarder) has `localPort` 0 and closes only the client.
   2. `close()` runs exactly once; later callers return at once. Gomobile `close()` takes the Go startup mutex and can block for seconds, so it runs off the caller's executor. The continuation is not cancellation-aware, so a cancelled caller still releases the handles. Closures capture the lock-guarded `self`, not the non-Sendable handles. `markClosed()` is synchronous because `NSLock.lock()` is unavailable in async contexts.
   3. `establishTimeoutMs` (20 s) covers first-use DERP discovery and a relay round-trip. It is much longer than the WebSocket connect timeout: the tunnel is the slow-path candidate, and reachable direct hosts win first.
   4. `DialHandle` bridges task cancellation to the blocking dial: `cancel()` records the time and closes the in-flight client off the cancelling thread, because close takes the same mutex that startup holds. It is idempotent. Before registration, the dial thread closes the client itself when `register(_:)` fails. Close cannot shorten `ping`: before first use it is a no-op, during startup it waits for startup, and during the wait it does not wake it (10 s internal cap). It only guarantees teardown, off the connect critical path.
15. **Transport errors.** `certificateMismatches` carries every per-host mismatch when no host won, not just the last. `missingCertificatePin` refuses a record without a trusted pin before any bearer can be sent. `relabeled(host:)` changes a single-route error's label only; aggregate mismatches keep each candidate's host.
16. **Network copy diagnostics.** `NetworkCopyDiagnostics` is temporary, opt-in phone evidence. It never accepts free-form text or writes data. Recording does not subscribe the presenter to later events.

## Consequences

- A stored record can grow hosts over time but never loses hosts through a refresh.
- A Tailcat session closes the forwarder before the client, because the forwarder rides the client's tunnel (from test comments).
- TailcatKit has no visionOS (`xros`) slice, so its tests compile only under `#if canImport(TailcatKit)`. The byte-exchange smoke test dials a `TailcatKit/cmd/tcecho` server that CI starts and names in `TAILCAT_SMOKE_TOKEN`; without it only that test skips. A gomobile read reports end of stream as an error whose description is "EOF", because an empty Go slice would bridge to nil `NSData` and break the `throws -> Data` projection (from test comments).

## Code

- `ConnectionManager`: `connect(…)`, `retryConnection()`, `performConnect(…)`, `teardownConnection()`, `disconnect()`, `certMismatches`, `connectAttempt`, `resetCertMismatchesIfTargetChanged(…)`, `updateCachedCredentials(…)`, `tunnelCandidateLabel`, `makePathMonitor`, `readSocketPath`, `connectInProcess(using:)`
- `ConnectionManager` (racing and recovery): `raceCandidates(…)`, `raceHosts(…)`, `WonHostRace`, `recordLateCertMismatches(…)`, `recordCertMismatches(_:)`, `connectViaTunnel(…)`, `handlePathUpdate(…)`
- `HostRaceOutcome`, `RacedConnection`, `RaceMailbox`, `TunnelEstablishmentFailure`
- `ConnectionManager` (startup, routes, requests): `readyRace(…)`, `observeStartupLifecycle()`, `scheduleHostRoutesRefresh()`, `refreshHostRoutes()`, `mergeHosts(existing:reported:)`, `refreshStoredDisplayName(token:port:context:)`, `hostRefreshIsCurrent(_:)`, `defaultRequestTimeout`, `awaitResponse(…)`, `startHeartbeat()`
- `ConnectionRequestTransport`: `makeInProcessTransport(…)`
- `TailcatTunnelSession`: `close()`, `markClosed()`; `TailcatTunnelDialer`: `establishTimeoutMs`; `DialHandle`: `register(_:)`, `cancel()`, `cancelledAt`
- `WebSocketTransportError`: `certificateMismatches`, `missingCertificatePin`, `relabeled(host:)`; `HostCertMismatch`
- `NetworkAvailability`: `acquire()`, `Lease`; `NetworkPathSnapshot`, `NetworkCopyDiagnostics`, `SocketPathObservation`: `ready(path:)`, `observe(_:)`

# ADR-0413: ConnectionManager lifecycle, requests, recovery and startup

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConnectionManager` (`Intent/Services/ConnectionManager.swift`),
  `ConnectionManagerRequests.swift`, `ConnectionManagerRecovery.swift`,
  `ConnectionManagerStartup.swift`, `ConnectionManagerHeartbeat.swift`,
  `ConnectionManagerBrowser.swift` (all in `Intent/Services/`)
- Related issues: intent-hq/intent#4185

## Context

`ConnectionManager` owns one daemon connection: connect, host racing,
reconnect, heartbeat, JSON-RPC requests, in-process transports for demo
launches, and the startup admission. Several instances can exist, one per
backend session.

## Decisions

### 1. One instance per backend session, plus the shared default

Applies to: `ConnectionManager.init(diagnostics:persistence:)`

The initializer is internal, not private, so `BackendSessionRegistry` can
build one more instance per pinned backend session. `.shared` stays the
process-wide default used by the default session and existing code.

### 2. Connections fail closed without a pin

Applies to: `ConnectionManager.validateTransportSecurity(hosts:certFingerprint:)`

The check runs before any state changes and before a socket opens. Otherwise a
pinless saved record could send its bearer token over plaintext.

### 3. A manual retry never weakens trust

Applies to: `ConnectionManager.retryConnection()`

A manual retry skips transport backoff. It does not replace a connected socket
or an initial connection attempt. Pin failures still require the pairing flow,
never an untrusted reconnect.

### 4. The newest overlapping connect wins

Applies to: `ConnectionManager.connectAttempt`

The preserving path (pairing over a live connection) does not tear down up
front, so it does not advance `connectionGeneration`, and overlapping attempts
share a generation. `connectAttempt` orders them, so the newest attempt wins
the adoption race whichever finishes first.

### 5. Certificate mismatches accumulate per target

Applies to: `ConnectionManager.certMismatches`, `ConnectionManager.teardownConnection()`,
`ConnectionManager.resetCertMismatchesIfTargetChanged(hosts:port:certFingerprint:)`,
`ConnectionManager.recordCertMismatches(_:)`, `ConnectionManager.recordLateCertMismatches(from:generation:)`,
`ConnectionManager.raceHosts(...)`

`certMismatches` holds every per-host mismatch seen while racing hosts for the
current target, with the latest fingerprint per host. It accumulates across
reconnect attempts. It is cleared by a fresh `connect()` to a different target
and by an explicit `disconnect()`. `teardownConnection()` does not touch it, so
`connect()` to the same target keeps the mismatches.

A different target is detected by port and pin when a pin is present. Host
lists drift, because `refreshHostRoutes()` merges daemon-reported IPs into
`hosts`, so a later connect from the stored record would look different under
exact host equality. Pinless targets fall back to host overlap.

Every observed mismatch is surfaced, even when a winner settled, unless a newer
`connect()` or `disconnect()` superseded the race. The race returns its
background drain to the caller, because only the caller knows which connection
generation the drain's late mismatches belong to. Late mismatches are recorded
when the drain finishes, unless `connectionGeneration` moved on.

### 6. Tunnel candidates

Applies to: `ConnectionManager.tunnelCandidateLabel`, `ConnectionManager.tcAddress`,
`ConnectionManager.activeTunnel`, `ConnectionManager.tunnelDialer`, `ConnectionManager.connectViaTunnel(...)`

1. `tcAddress` is the Tailcat tunnel address of the current target, nil when
   the daemon has no tunnel. When present it adds the tunnel candidate to host
   racing.
2. `tunnelCandidateLabel` is the label the tunnel route races under, and the
   host shown in its transport errors. It is not a dialable name; the tunnel
   connects through a loopback forwarder.
3. `activeTunnel` is the tunnel session carrying the live socket, nil when a
   direct host won. It is closed on teardown.
4. `tunnelDialer` is injectable for tests. It defaults to the real
   TailcatKit-backed dialer where the xcframework links (iOS), and to the
   always-failing stub on visionOS, which has no xros TailcatKit slice yet.
5. `connectViaTunnel` establishes the tunnel (including its slow first-use
   warm-up), then completes the normal pinned WSS handshake through the
   tunnel's loopback forwarder. The tunnel is closed on any failure after
   establishment, so a lost race never leaks the session. The function is
   static with an injected dialer so tests can drive it. Loopback transport
   errors are relabeled to the tunnel candidate, so failures show against a
   route the user recognizes, and a certificate mismatch never collides with a
   real "127.0.0.1" host entry.

### 7. Rotated credentials are adopted without dropping the socket

Applies to: `ConnectionManager.updateCachedCredentials(hosts:port:token:certFingerprint:tcAddress:)`

When a synced-registry merge rewrites the active connection's stored record,
the cached hosts, port, token and fingerprint used by reconnect racing and ping
recovery are refreshed, so they use the rotated token and current routes. The
live socket is kept, because the daemon checks the token only at the WebSocket
upgrade.

### 8. In-process connections

Applies to: `ConnectionManager.isInProcessConnection`, `ConnectionManager.requestTransport`,
`ConnectionManager.connectInProcess(using:)`

`isInProcessConnection` is set while connected without a daemon socket
(pretend-paired launches). Readiness then follows the connection state
directly. `connectInProcess` marks the connection live without a socket, and
requests go to the transport.

### 9. Reconnect stop reason

Applies to: `ConnectionManager.reconnectStopReason`

It says why reconnection stopped for good (for example revoked access). It is
cleared on connect.

### 10. Combine publishers exist for compatibility

Applies to: `ConnectionManager.connectionStatePublisher`, `ConnectionManager.certMismatchPublisher`

`connectionStatePublisher` serves stores that depend on
`ConnectionManagerRouting`. `certMismatchPublisher` serves `AppCoordinator`'s
certificate-mismatch routing.

### 11. Heartbeat and path monitoring

Applies to: `ConnectionManager.startHeartbeat()`, `ConnectionManager.heartbeatTask`,
`ConnectionManager.heartbeatClock`, `ConnectionManager.makePathMonitor`,
`ConnectionManager.readSocketPath`, `ConnectionManager.handlePathUpdate(_:monitorID:)`

1. The heartbeat sleeps one cadence interval, then probes the live socket.
   Probes run one at a time and are guarded by generation and socket, so a
   retired result is ignored. Tests read `heartbeatTask` as a completion
   barrier for a retired heartbeat.
2. `heartbeatClock` is the time source for heartbeat cadence, probe deadlines
   and subscription retry backoff.
3. A fresh path monitor is created for every live socket, because
   `NWPathMonitor` is one-shot.
4. `readSocketPath` injects endpoint evidence. General path reports cannot
   disprove a direct route.
5. An embedded tunnel's local socket cannot observe its remote underlay, so
   path updates act only when a tunnel is active. Direct sockets, including
   system VPNs, use only their endpoint evidence. Preference or virtual-name
   changes alone do not invalidate a serving tunnel; only a dead path or a lost
   physical interface does.

### 12. Requests

Applies to: `ConnectionManager.notConnectedRequestError()`, `ConnectionManager.defaultRequestTimeout`,
`ConnectionManager.request(_:params:timeout:)`, `ConnectionManager.awaitResponse(id:timeout:write:)`

1. `notConnectedRequestError()` is the error a request gets when no admitted
   connection can answer it.
2. `defaultRequestTimeout` is 10 seconds. A call may pass a longer timeout when
   the daemon operation is known to outlast it (for example
   `workspace.create`). Long-running operations must pass a bound above the
   daemon's own budget, so the daemon's structured result (success or error)
   wins over a client-side transport timeout. This matches the per-call
   `timeoutMs` override in cloudlands-fe.
3. Each pending continuation is resumed exactly once. Whoever removes the entry
   from `pendingRequests` (all on `MainActor`) owns the resume: a response in
   `handleTextMessage`, a disconnect in `failAllPending`, or the timeout task.
   A daemon that never responds therefore still produces the timeout error,
   instead of suspending forever, because a suspended `CheckedContinuation`
   does not observe task cancellation.

### 13. Startup admission

Applies to: `StartupAdmissionRun`, `ConnectionManager.readyRace(...)`,
`ConnectionManager.observeStartupLifecycle()`, `ConnectionManager.setStartupSuspended(_:)`

1. A connection runs at most one bootstrap admission, tracked by
   `StartupAdmissionRun`.
2. Every initial connection and recovery goes through `readyRace`. Racing only
   opens a transport. Normal subscriptions cannot see a bootstrap seat.
3. A new startup snapshot replaces the old one entirely. This also drops
   counters and ETA when the daemon's attempt ID changes or a future schema is
   not recognized.
4. Process lifecycle, not a single iPad window, owns suspension, so one
   background scene cannot stop another window's active backend session.
5. On suspension, a failed state is kept so Retry stays, because a failure has
   no admission left to resume.

### 14. The browser proxy uses the winning route

Applies to: `ConnectionManager.makeBrowserProxy()`

The proxy uses the winning route, including the existing Tailcat loopback
forwarder. The auxiliary tunnel keeps bearer credentials out of browser
content. It reads `protocolVersion` from `system.status`, which exposes the
same value as `client.hello` without replacing the live RPC connection's
client identity.

### 15. Recovery backoff restarts only after a stable socket

Applies to: `ConnectionManager.reconnectStartingAttempt(connectionLifetime:previousAttempt:)`

A socket that lived at least `stableConnectionThreshold` (10 s) restarts
recovery at the first attempt, with no backoff. A shorter-lived socket
continues the backoff from its previous attempt.

### 16. A failed pairing does not abandon a running reconnect

Applies to: `ConnectionManager.connect(...)`

A pairing that fails while the manager is reconnecting keeps the reconnect loop
and its original target. It never leaves the app on `.connecting` for the
failed target (intent-hq/intent#4185).

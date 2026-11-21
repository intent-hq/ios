# ADR-0607: Network availability is presentation-only path evidence

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `NetworkAvailability` (`Intent/Services/NetworkAvailability.swift`), `NetworkCopyDiagnostics` (`Intent/Services/NetworkCopyDiagnostics.swift`), `NetworkPathSnapshot` (`Intent/Services/NetworkPathMonitoring.swift`), `SocketPathObservation` (`Intent/Services/SocketPathObservation.swift`)

## Decisions

### 1. `NetworkAvailability` is presentation-only

Applies to: `NetworkAvailability`

It reports default-path evidence for the UI. It is independent of socket and
retry ownership. Neither a satisfied nor an unsatisfied general path proves
that an endpoint is reachable.

### 2. One shared instance, separate from the socket monitor

Applies to: `NetworkAvailability.shared`

The instance is shared across windows. It is not shared with
`ConnectionManager`'s per-socket monitor.

### 3. Leases follow foreground scenes

Applies to: `NetworkAvailability.acquire()`, `NetworkAvailability.Lease`

Retain one lease per foreground scene, including startup and reconnection.
Cancel or release it on background or teardown, not on socket replacement or
loss. After the last release, the next acquire waits for a fresh real path
callback. `Lease.cancel()` is idempotent, and the lease also releases itself
automatically at scene teardown.

### 4. Network copy diagnostics never take free text

Applies to: `NetworkCopyDiagnostics`, `NetworkCopyDiagnostics.entries`

The diagnostics are temporary, opt-in phone evidence. They never accept free-form text and never write
data. `entries` is not observed, so recording does not subscribe the presenter
to later diagnostic events.

### 5. Path snapshot field meanings

Applies to: `NetworkPathSnapshot`

1. `unsatisfiedReason` is meaningful only for an unsatisfied path. It is not a
   diagnosis of Airplane Mode.
2. `physicalInterfaces` lists the physical members in `NWPath`'s preference
   order, even under a virtual primary interface.
3. `isSatisfied` keeps the transport's existing satisfied/not-satisfied
   interpretation (only `.satisfied` counts).
4. Interfaces are classified from interface metadata, never from name
   prefixes.

### 6. Socket path observation is per-connection evidence

Applies to: `SocketPathObservation` (`Intent/Services/SocketPathObservation.swift`)

1. `SocketPathObservation` captures connection-queue evidence before the
   connection is adopted, without actor-hop ordering races. A general
   `NWPathMonitor` describes default routing, not this endpoint's
   reachability.
2. `ready(path:)` is called on `.ready`. It replaces setup-time path and
   viability with established evidence.
3. `observe(_:)` installs the observer and replays atomically. Notifications
   read the current state, not an older captured value that could arrive after
   a newer update on the main actor.

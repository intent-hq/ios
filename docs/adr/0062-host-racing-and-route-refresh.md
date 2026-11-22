# ADR-0062: Host racing settles on the first winner, and route refresh only adds hosts

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `HostRacingConnection`, `RacedConnection`, `HostRaceOutcome`,
  `TunnelEstablishmentFailure`, `RaceMailbox`, `ConnectionManager.raceCandidates`
  (`Intent/Services/ConnectionHostRacing.swift`),
  `ConnectionManager` host route refresh (`Intent/Services/ConnectionManagerHostRefresh.swift`)
- Related issues: ios#341

## Context

A saved connection can have several hosts (LAN addresses, NAT names) and a
Tailcat tunnel route. The app races them on connect. After a connect, the
daemon reports its current addresses and the app updates the saved routes.

## Decisions

### 1. The race settles on the first success without waiting for losers

Applies to: `ConnectionManager.raceCandidates(_:diagnostics:connect:)`, `HostRaceOutcome.drain`

One connect attempt runs per host. The race settles on the first success. The
remaining candidates are cancelled and drained by a background task that
disconnects late successes and reports late certificate mismatches, so a slow
loser never delays a connect that has already won. `drain` is nil when every
candidate had already finished. A losing tunnel session is never leaked.

Mismatches observed before settling are collected on the outcome, so the
winner does not swallow a loser's mismatch. When no candidate succeeds, every
candidate is awaited, and `failure` prefers an aggregate certificate error over
generic failures.

Cancelling the losers runs each candidate's task cancellation handlers
synchronously on the settling thread. Candidate cancellation handlers must not
block, or the settle stalls inside `cancelAll()`. The tunnel dial's
`DialHandle.cancel()` closes off-thread for this reason.

The race is generic over `HostRacingConnection`, the minimal surface it needs,
so tests can race fakes instead of live sockets.

### 2. Candidates run as unstructured tasks feeding a mailbox

Applies to: `RaceMailbox`

A task group's body cannot return before every child finishes, which is
exactly the stall a slow loser would cause. Candidates therefore run as
unstructured tasks and deliver to a single-consumer mailbox. Unlike
`AsyncStream`, delivery keeps working after the consuming task is cancelled, so
cleanup can still drain every candidate.

### 3. A raced connection owns its tunnel

Applies to: `RacedConnection`

`RacedConnection` is the WebSocket plus the Tailcat tunnel session carrying it
(nil for direct hosts). `disconnect()` tears down both, so loser cleanup
releases tunnel resources when a direct host wins. `host` is the candidate
label: the direct host, or `ConnectionManager.tunnelCandidateLabel` for the
tunnel route.

### 4. Tunnel failures keep the underlying error

Applies to: `TunnelEstablishmentFailure`

The wrapper carries the tunnel phase to the race without changing the failure
returned to connection owners. Cancellation and trust errors survive.

### 5. Late losers report only real pin rejections

Applies to: `ConnectionManager.makeDrain(...)`

Losing candidates are cancelled on purpose. A concrete late pin rejection still
matters and is recorded. Generic cancellation fallout is not another
connection failure.

### 6. Route refresh never delays a connect and never fails it

Applies to: `ConnectionManager.scheduleHostRoutesRefresh()`, `ConnectionManager.refreshHostRoutes()`

Every successful connect path (initial connect and reconnect) schedules the
refresh as fire-and-forget, so it never delays the connection becoming usable.
The refresh queries `system.status` for the daemon's `localIps` and merges them
into the in-memory host list used by reconnect racing and into the persisted
`StoredConnection`, updated by record id. Failures are non-fatal: older daemons
without `localIps` and transport errors are skipped, and the connection goes on
unchanged. `localIps` absent or malformed means unavailable. `tcAddress` absent
(older daemon, tunnel not running), malformed or blank means nil.

### 7. The display name refreshes first

Applies to: `ConnectionManager.refreshStoredDisplayName(token:port:context:)`

The stored display name is refreshed from `host.status` before the `localIps`
flow, because it must run even when that flow bails out (older daemon,
transport hiccup). The order is prettyHostname, then hostname, then keep the
existing name. Connections saved before the daemon reported a pretty name heal
on the next successful connect. Failures keep the existing name. A reconnect,
credential import or local route edit can supersede the reply while the
admitted socket stays usable, so the reply is checked for currency first.

### 8. Persist only to the record actually connected through

Applies to: `ConnectionManager.applyReportedHosts(_:token:port:)`,
`ConnectionManager.applyReportedTunnelAddress(_:token:port:)`, `ConnectionManager.savedConnection(token:port:)`

Updates go to the active connection, verified against the live token and port.
During initial pairing the active record is still the previous one, or absent,
until `ConnectionPairing.finalize` saves and activates the new record and
triggers this refresh again. Token and port alone would be ambiguous, because
the same daemon can be saved as separate records with different host sets at
the same port.

Hosts are merged against the stored hosts, not only the in-memory merge. The
session may have connected with a narrower host list than the record holds (for
example a single-host manual re-pair while the record also has a NAT hostname).
Persisting the in-memory merge alone would drop those hosts.

### 9. Host merging only appends

Applies to: `ConnectionManager.mergeHosts(existing:reported:)`

Existing hosts (originally paired or entered) keep their order and are never
dropped. Reported IPs that are not present are appended. Deduplication is
case-insensitive, because DNS names and IPv6 hex are case-insensitive
(ios#341), and keeps the first spelling seen. Reported values are untrusted and
must be valid URL host components. Raw IPv6 literals are bracket-normalized
before they can be raced or persisted.

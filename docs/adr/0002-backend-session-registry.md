# ADR-0002: One shared, refcounted session per saved backend

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `BackendID` (`Intent/App/BackendID.swift`), `BackendSession`, `SessionConnectionManaging` (`Intent/App/BackendSession.swift`), `BackendSessionRegistry` (`Intent/App/BackendSessionRegistry.swift`)
- Related issues: ios#254

## Context

The app can show several windows. Each window is bound to one saved backend
(a paired Mac), and several windows can show the same backend. The connection
and the stores for a backend must be shared by those windows, but each window
must navigate on its own. This is "window model v2" and the "State split" in
the spec.

## Decisions

### 1. `BackendID` wraps the saved connection id

Applies to: `BackendID`

`BackendID` is the stable identity of a saved backend across launches. It
wraps `StoredConnection.id`. It is `Hashable` and `Codable` so it can be the
`WindowGroup(for:)` presentation value on visionOS and the dictionary key in
`BackendSessionRegistry`. It is `nonisolated` because it is a plain value type
that nonisolated helpers use, for example notification tap routing.

### 2. The registry creates a session on first attach and tears it down on last detach

Applies to: `BackendSessionRegistry.attach(_:)`, `BackendSessionRegistry.detach(_:)`

`BackendSessionRegistry` is a process-global map from `BackendID` to
`BackendSession`. The first attach creates the session. Later attaches share
it, one attach per window that shows the backend. Every attach must be
balanced by one detach. The last detach disconnects the backend connection and
releases the session. A later attach for the same backend creates a fresh
session. Unbalanced detaches are no-ops.

There is no default session. Every window is bound to exactly one backend.

### 3. Pairing sessions are not registered

Applies to: `BackendSessionRegistry.makePairingSession()`, `BackendSession.backendID`

A window with no backend yet (first run, or a window unbound after its backend
was removed) gets a fresh transient session with a nil `backendID`. It is not
registered or refcounted. The owning window tears it down when pairing
completes or the window closes. `backendID` is nil only for this kind of
session.

### 4. Removal marks drive window closing, not session teardown

Applies to: `BackendSessionRegistry.removedBackendIDs`, `markBackendRemoved(_:)`, `markBackendsRemoved(_:)`, `clearRemovedMarks(_:)`

`removedBackendIDs` holds backends whose saved connection was removed while
the app runs: a user delete, a log off, or a synced tombstone (spec decision
2). The registry is `@Observable` so windows can react: a window on a removed
backend unbinds or closes. Marking never tears a session down by itself. The
closing window's detach drives the normal teardown.

- `markBackendRemoved(_:)` is idempotent. Any pinned window on that backend auto-closes.
- `markBackendsRemoved(_:)` marks several at once, for synced-merge tombstones.
- `clearRemovedMarks(_:)` clears marks when a saved connection reappears (a
  synced merge re-added the same record id), so a later pinned window on the
  resurrected backend is not closed on sight.

### 5. Hooks for process-wide observers

Applies to: `onSessionCreated`, `onSessionTeardown`, `onBackendsRemoved`, `SessionFactory`

- `onSessionCreated` runs after a backend session is created, so process-wide
  aggregators such as `NotificationManager` can observe its connection. It
  does not run for pairing sessions.
- `onSessionTeardown` runs when a session is released on last detach, before
  its connection is torn down.
- `onBackendsRemoved` runs when saved connections are removed, while their
  sessions may still be live.
- `SessionFactory` builds a session for a backend (nil means a pairing
  session). The default is the live composition root. Tests inject a factory
  that builds sessions over fakes.

### 6. A user selection is remembered once, in memory

Applies to: `BackendSessionRegistry.markConnectionSelected(_:)`, `consumeConnectionSelection(for:)`

A user selection may create a new window and coordinator whose loading route
otherwise looks identical to cold-launch restoration. The registry remembers
the selection so the new coordinator can tell the two apart. The mark is never
persisted.

### 7. Every session gets fresh per-backend instances

Applies to: `BackendSessionRegistry.makeLiveSession(backendID:)`, `BackendSession`

`makeLiveSession` is the composition root for real sessions. Every session
gets fresh per-backend instances; there is no `.shared` state split.
`BackendSession` is one backend's runtime state: the connection plus the
per-window stores and loaders from the spec's state split. It never reads
process-wide singletons.

### 8. Windows on one session navigate independently; the first one restores

Applies to: `BackendSession.makeCoordinator(startingAtSavedMachines:)`, `BackendSession.claimScreenRestoration()`, `BackendSession.CoordinatorFactory`

`makeCoordinator` gives each window a fresh coordinator. Windows that share
the session share the connection and stores but navigate independently (spec
"State split"). The `claimScreenRestoration` parameter of `CoordinatorFactory`
is the coordinator's lazy hook into `BackendSession.claimScreenRestoration()`.

`claimScreenRestoration()` grants last-screen restoration to the first
claimant only. The first window on a backend restores that backend's saved
screen. Duplicated windows start at the workspace list. Pairing sessions have
no backend to restore.

`startingAtSavedMachines` skips the launch splash after an explicit return
Home, including in demo mode. It starts no connection attempt.

### 9. A hijacked shared connection is re-dialed by a window that stays

Applies to: `BackendSession.repairConnection(leaving:)`

A pairing from one window can dial another daemon over this session's shared
connection while that window switches away. One window that stays on this
backend re-dials it. With no window left, the registry tears the session down
when the leaving window detaches.

### 10. Session-lifetime caches

Applies to: `BackendSession.agentDetails`, `githubRepoStore`, `creationOptionsStore`, `retainWorkspaceStatus(workspaceId:consumer:)`, `teardown()`

- `agentDetails` is the authoritative detail state shared by routes,
  conversations, and proposal cards.
- `githubRepoStore` caches GitHub repos for the New Workspace repo step for
  the session's lifetime. It outlives the sheet so a reopen renders the cached
  list instantly. `creationOptionsStore` caches specialists, providers, and
  models for the New Workspace final step with the same contract.
- The window keeps the workspace status leases from `retainWorkspaceStatus`
  across conversation switches in its selected workspace. Conversation and row
  leases share the exact same caches.
- The registry calls `teardown()` when the last window detaches.

### 11. The session's connection surface

Applies to: `SessionConnectionManaging`

`SessionConnectionManaging` is the connection surface a `BackendSession`
owns: the routing seam the stores already use, plus the lifecycle, credential,
and certificate surfaces that the coordinator and the connection views drive
on their own session instead of a process-wide singleton.
`ConnectionManager` conforms as-is. Tests inject fakes.

- `connectionState` is settable so demo mode can mark the session connected without a socket.
- `certMismatches` holds the per-host certificate mismatches observed by the current race.
- `certMismatchDetected` is raised when a pinned certificate changed. The
  coordinator clears it once it has routed to the failure screen.
- `tunnelDialer` probes a server certificate over a Tailcat tunnel.
- `globalSubscriptionState` is `.failed` once the bounded retries of the live
  socket's global event subscription are exhausted. The window then shows a
  retry action routed to `retryGlobalSubscription()` (ios#254).
- `reconnectStopReason` says why automatic reconnection stopped for good. It is nil while the connection may recover.
- `lastConnectedPrincipal` is the person last confirmed on a live connection,
  kept through a drop that keeps reconnecting. Use it for read-only
  navigation only, never for authority.
- `connectAttemptCount` counts connect attempts started on the session, so a
  caller whose connect was cancelled can tell whether a newer attempt replaced it.

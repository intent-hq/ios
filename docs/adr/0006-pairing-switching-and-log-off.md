# ADR-0006: Pairing, switching, and logging off a window's backend

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AppCoordinator` routing (`Intent/App/AppCoordinatorRouting.swift`), `AppCoordinator.retargetWindow`, `retargetRoute`, `choosesBackendInPlace`, `repairSharedConnection`, `returnWindowToSavedMachines`, `backendID`, `savedConnections`, `savedConnectionsUndecodable` (`Intent/App/AppCoordinator.swift`), `AppCoordinator.onIPadPairedConnection(_:)` (`Intent/App/AppCoordinatorIPadNavigation.swift`)

## Context

A window's coordinator pairs new backends, switches between saved
connections, merges synced connections, and logs off. Window-level routing is
owned by the window root (ADR-0003). The coordinator must work with and
without that root, because tests and previews have no root.

## Decisions

### 1. The window root owns retargeting

Applies to: `AppCoordinator.backendID`, `retargetWindow`, `retargetRoute`, `choosesBackendInPlace`

`backendID` is nil only for a window with no backend yet (a pairing session).
Bound windows route straight to `.connecting` on load and dial the backend's
saved record.

`retargetWindow` is set by the window root (`BackendWindowRoot`) under
`WindowRetargetRoute`: rebind in place, replace an unbound pairing window, or
on visionOS open the target's own window. When it is unset (tests, previews),
switch and pair actions fall back to in-place routing over the session's
connection. `retargetRoute` reports the route `retargetWindow` will take;
when it is unset, a retarget counts as a rebind in place.

A window that is not showing a connected machine (Home, pairing, connecting, or
a connection failure) picks another machine in place instead of opening that
machine's window beside it (`choosesBackendInPlace`).

### 2. The root owns the attachment count

Applies to: `AppCoordinator.returnWindowToSavedMachines`, `repairSharedConnection`, `onReturnToSavedMachines()`

`returnWindowToSavedMachines` detaches only this window and supplies a fresh
pairing session. The root, not the coordinator, owns the registry's attachment
count. `repairSharedConnection` is set by the session and hands a hijacked
shared connection's re-dial to a window that stays on the backend; when unset,
this window re-dials.

`onReturnToSavedMachines()` leaves the remote session without forgetting the
pairing. Unlike Log Off, it never edits credentials or marks the backend
removed. With no window owner (standalone tests, previews) it disconnects in
place. A live window must use the hook so surviving windows keep their connection.

### 3. Pairing routes to the paired backend's window

Applies to: `AppCoordinator.onDeepLinkPaired(_:)`, `onPaired(_:)`, `onIPadPairedConnection(_:)`

- A deep-link re-pair of the window's own backend (same record id, for example
  a rotated token) updates the cached credentials and restarts this window's
  attempt so it dials the refreshed record.
- Any other pairing (QR scan, manual entry, or a deep link for another backend)
  goes through `onPaired`, and the root's retarget hook applies the v2 policy:
  rebind in place on single-window platforms; open or raise the new backend's
  window, or replace an unbound pairing window with it, where multiple windows
  are supported. Without a hook, the pairing session's live connection is used in place.
- Retargeting to the same backend while the window is not showing remote UI
  does not change the window's binding. Initial routing, including its
  workspace-data wait, restarts explicitly instead of leaving the failure screen up.
- The pairing dialed the new backend over this window's live session
  connection. A window still on the old backend must re-dial it, or it keeps
  showing the newly paired daemon's data over the hijacked socket. Opening the
  target's own window keeps this window on its backend, so it re-dials
  (`redialWindowBackend()`). Otherwise the retarget replaces this window's
  coordinator and a sibling window re-dials (`repairSharedConnection`).
- `redialWindowBackend()` drops the hijacked socket and the other daemon's
  workspace data, then restarts the attempt. `ConnectingView` dials from
  `windowConnection`, the window's own saved record.
- Embedded iPad pairing (`onIPadPairedConnection`) dials a temporary session,
  so the window's connection was never borrowed and must not be torn down to
  repair it on success.

### 4. Window identity scopes saved-record actions

Applies to: `AppCoordinator.windowConnection`, `onLogOff()`

`windowConnection` is the saved record this window shows. Settings renders it
and Log Off forgets it. It is always scoped to this window's backend, never a
global pointer. `onLogOff()` uses the window's identity, not an optional
storage lookup that can disappear on a read failure and falsely report a
successful Log Off.

### 5. Removal routes out through the registry mark

Applies to: `AppCoordinator.onDeleteConnection(id:)`, `onLogOff()`, `exitRemovedBackend()`, `handleFailedLogOff()`

Deleting a connection or logging off forgets that backend only. Every window
on it, including this one, leaves through the registry's removal mark: the
window root closes the window, or rebinds a last remaining window to the
pairing surface, offering any remaining saved connections.

`exitRemovedBackend()` is the in-place route-out for a backend this window may
no longer show (Log Off, deleting this window's connection, or a synced
tombstone). It drops the live connection and lands on the pairing surface,
offering any remaining saved connections. In the running app the root's
removal observation supersedes it; it covers windows without a root hook
(tests, previews).

A user-requested log off always disconnects, even when the saved record cannot
be forgotten. `handleFailedLogOff()` keeps persistence-derived state intact and
shows the failure (`.manualLogOff`) instead of routing to first-run pairing.

### 6. Switching connections

Applies to: `AppCoordinator.onSwitchConnection(id:)`

A switch marks the target as the last-used backend and clears its saved screen
state, so a switch lands on the workspace list as before. It then routes
through the root's retarget hook (in place, or the target's own window on
visionOS). Without a hook it dials in place.

### 7. Stale workspace data is forgotten before reconnecting

Applies to: `AppCoordinator.resetWorkspaceStore()`

The previous daemon's workspace data is dropped so no stale rows show after
reconnecting, and so `ConnectingView.waitForWorkspaceData` (which polls
`lastUpdated`) really waits for the new daemon.

### 8. Synced backend merge

Applies to: `AppCoordinator.refreshSyncedBackends()`, `onScenePhaseActive()`, `onLoadComplete()`, `AppCoordinator.savedConnections`, `savedConnectionsUndecodable`

`refreshSyncedBackends()` merges the iCloud-synced backend registry into the
saved connections (see `SyncedBackendConnectionMerge`). It runs on load and on
every scene activation, so changes made on other devices while the app was in
the background show up.

- An unavailable registry read (locked keychain, missing entitlement) is a no-op. Local knowledge is kept.
- `savedConnectionsUndecodable` is true when the saved-connections store exists but cannot be decoded; the merge is then skipped.
- Tombstones close windows on the removed backends. A re-added record (the same id resurrected from another device) clears its mark.
- When a tombstone removes this window's backend, the window disconnects and
  routes away like Log Off; the root's removal observation closes or rebinds it.
- When the merge rewrote this window's record (rotated token, new routes), the
  live `ConnectionManager` cache adopts the new fields so the next reconnect uses them.
- A merge while the pairing surface is up must offer or stop offering the
  saved connections it added or removed. An unbound window offers synced
  connections merged from the registry, or saved earlier, on the pairing surface.
- `savedConnections` is the Settings snapshot, refreshed after the local and iCloud merge.

### 9. Notification taps and stashed work

Applies to: `AppCoordinator.handleNotificationSelection(agentId:workspaceId:agentName:connectionId:)`, `onLoadComplete()`, `onScenePhaseNotActive()`, `onInitialWorkspaceLoadComplete(attemptID:)`

- Notification taps route at once when the connected UI is stable, or are
  stashed until cold-start routing completes. Taps for a backend this window
  does not show are dropped; the multi-window tap route opens the source
  backend's own window.
- A deep link that arrived during the cold-start load is surfaced in
  `onLoadComplete()`, over whichever screen the load routed to.
- When the scene leaves the foreground, a background task begins so
  agent-completion events keep arriving during iOS's extended background execution window.
- `onInitialWorkspaceLoadComplete` keeps the existing bounded startup fallback,
  even during a transport-owned reconnect. Routing completion alone does not
  establish overlay eligibility (ADR-0005).

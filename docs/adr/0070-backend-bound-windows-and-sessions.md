# 0070. Backend-bound windows and shared backend sessions

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The app can show several daemons ("backends") at the same time. iPad and visionOS can open several windows. Windows on the same backend must share one connection and one set of stores, but navigate independently. A pairing can start from any window, and a saved connection can be removed by the user, by Log Off, or by a synced tombstone from another device ([ADR 0051](0051-backend-sync-and-invited-sessions.md)). This model is called "window model v2" in older code and issues.

## Decision

1. **One backend per window.**
   1. Every window is bound to exactly one backend, or to a transient pairing session when it has no backend yet. There is no default session and no process-wide connection singleton.
   2. `BackendID` wraps `StoredConnection.id`. It is `Hashable`, `Codable` and nonisolated, so it is a `WindowGroup(for:)` scene value, a registry key, and usable from nonisolated routing helpers.
   3. The scene value is the binding contract. A nil value (plain launch, restoration loss) binds once to the last-used backend. With nothing paired, the window runs a pairing session until a pairing rebinds it.
   4. Settings, Log Off and the window title use the window's own record (`windowConnection`, `windowConnectionID`), never a global pointer. Log Off uses the window identity, not a storage lookup that can fail and falsely report success.
2. **Sessions.**
   1. `BackendSessionRegistry` creates a `BackendSession` on the first `attach(_:)` and shares it with later attaches. Every attach is balanced by one `detach(_:)`. The last detach disconnects and releases the session. A later attach creates a fresh session. An unbalanced detach is a no-op.
   2. Pairing sessions (`makePairingSession()`) are not registered or counted. The owning window tears them down.
   3. `makeLiveSession(backendID:)` composes fresh per-backend instances for every session. A session never reads process-wide singletons.
   4. `makeCoordinator(startingAtSavedMachines:)` gives each window its own `AppCoordinator` over the shared session. `SessionWindowRoot` keeps it in `@State`. A rebind builds a fresh root (`.id(ObjectIdentifier(session))`), never updates the old one in place.
   5. `githubRepoStore` and `creationOptionsStore` live for the session, so a reopened New Workspace sheet renders cached lists at once.
   6. Process-wide aggregators (`NotificationManager`) observe each backend session from `onSessionCreated` until teardown. Pairing sessions carry no backend and are not observed.
3. **Retargeting** (`WindowRetargetRoute`).
   1. iPhone and iPad switch a bound window in place (ios#897). "Open in New Window" is the explicit iPad multi-window path.
   2. On visionOS every backend has its own window. Picking another machine opens or raises that window, and the current window stays.
   3. A window that is not showing a connected machine (Home, pairing, connecting, failure) chooses in place (`choosesBackendInPlace`).
   4. Where multiple windows exist, an unbound pairing window is replaced by the target's own window, so the bound window keeps a scene value that `openWindow(value:)` can raise. The pairing window is dismissed only after the replacement scene connects (`dismissWhenReplacementConnects()`).
   5. A re-pair of the window's own backend (same record id, for example a rotated token) restarts the attempt with the refreshed record. Any other pairing routes through `onPaired(_:)`.
   6. `onSwitchConnection(id:)` marks the target last-used and clears its saved screen, so a switch lands on the workspace list.
4. **Home, Log Off and removal.**
   1. Home (`onReturnToSavedMachines()`) leaves the session without forgetting the pairing. It never edits credentials or marks the backend removed. The window's attachment is owned by the root (`BackendWindowSession`), not by the coordinator. The native scene value stays, so `openWindow` can still raise the window.
   2. Log Off and `onDeleteConnection(id:)` forget only that backend. A requested Log Off always disconnects. When the record cannot be forgotten, the app keeps persistence-derived state and shows the failure (`handleFailedLogOff()`), and does not route to first-run pairing.
   3. Removal marks the backend in `removedBackendIDs`. A mark never tears a session down by itself. A window on a removed backend detaches at once and dismisses itself. The app's last window rebinds to pairing instead, so the app never has zero windows (`RemovedWindowCloseAction.forWindowCounts`). Sibling windows still attached to the removed backend do not count as survivors, so two such windows never both dismiss.
   4. The mark is observed with `initial: true`, so a mark set before the window rendered still closes it. A window restored after its record was removed marks itself.
   5. If a dismissal cannot be delivered, `RemovedBackendPlaceholderView` names the state and offers a manual close that works even for the last window.
   6. A synced merge that re-adds a removed record id clears its mark (`clearRemovedMarks(_:)`).
5. **Sync on foreground.** `onScenePhaseActive()` re-merges the iCloud registry (`refreshSyncedBackends()`). An unavailable read keeps local knowledge. A tombstone on this window's backend routes away like Log Off. A rewritten record (rotated token, new routes) updates the live connection's cached credentials.
6. **Shared socket.** A pairing dials over the window's session connection. A window that stays on its old backend must re-dial (`redialWindowBackend()`, `repairConnection(leaving:)`), and drops the other daemon's workspace data first (`resetWorkspaceStore()`). Agent history forgets a workspace only when the socket reaches this window's own device (`socketReachesWindowDevice`).
7. **Per-window behaviour.**
   1. On multi-window platforms, only the source backend's window renders an alert toast and plays its feedback (`windowPresentsAlert`). On iPhone, taps navigate in place.
   2. Each window registers its own agent-selection handler and removes only its own registration (`selectionHandlerToken`). A pairing window registers none.
   3. On visionOS, alert sounds are emitted from the source window's scene for spatial audio. Other platforms keep global sounds.
   4. Remote read-only state is per window, so a drop on one Mac never disables another window.
   5. `WindowSceneTitle` publishes the backend label through the view's own scene, outside navigation and session identity. A transient removal keeps the last title. A locked Keychain never erases a known label; a successful read with no record clears it.
   6. Network observation is scene-owned (`updateNetworkObservation(for:)`), so Home, rebinds and retries keep one lease.
8. **Demo launches.** A fresh demo launch ignores a restored Home flag and stale scene values, so connection and settings demos use the process's fresh fixtures. Explicit Home navigation is honoured for the rest of the window's life (`restoreSavedMachines(_:isDemo:)`).

## Consequences

- Windows on one backend share data but never share navigation.
- Any code path that pairs must account for the shared socket until pairing uses its own connection.
- Tests and previews without a window root fall back to in-place routing; production always has a root hook.

## Code

- `BackendID`, `BackendSession`: `makeCoordinator(startingAtSavedMachines:)`, `repairConnection(leaving:)`, `teardown()`
- `BackendSessionRegistry`: `attach(_:)`, `detach(_:)`, `makePairingSession()`, `markBackendRemoved(_:)`, `markBackendsRemoved(_:)`, `clearRemovedMarks(_:)`, `removedBackendIDs`, `onSessionCreated`, `makeLiveSession(backendID:)`
- `BackendWindowSession`: `sceneTitle`, `updateNetworkObservation(for:)`, `restoreSavedMachines(_:isDemo:)`, `rebind(to:)`
- `SessionWindowRoot`, `BackendWindowRoot`: `bindCurrentBackend()`, `retarget(to:choosingInPlace:)`, `dismissWhenReplacementConnects()`, `closeRemovedWindow()`
- `WindowRetargetRoute`, `RemovedWindowCloseAction`, `RemovedBackendPlaceholderView`, `WindowSceneTitle`
- `AppCoordinator`: `backendID`, `retargetWindow`, `retargetRoute`, `choosesBackendInPlace`, `repairSharedConnection`, `returnWindowToSavedMachines`, `windowConnection`, `windowConnectionID`, `onDeepLinkPaired(_:)`, `onPaired(_:)`, `onSwitchConnection(id:)`, `onDeleteConnection(id:)`, `onLogOff()`, `onReturnToSavedMachines()`, `refreshSyncedBackends()`, `handleNotificationSelection`, `forgetHistory(ofWorkspace:)`
- `RootView`: `feedbackEventForThisWindow`, `selectionHandlerToken`

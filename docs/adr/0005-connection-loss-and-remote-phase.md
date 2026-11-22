# ADR-0005: Connection loss presentation and the remote phase

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AppCoordinator` (`Intent/App/AppCoordinator.swift`), `AppCoordinatorLifecycleState` (`Intent/App/AppCoordinatorLifecycleState.swift`), `ConnectionLossPresentation` (`Intent/App/ConnectionLossPresentation.swift`), `RemoteConnectionPhase` (`Intent/App/AppCoordinatorRemotePhase.swift`), `ConnectionScreen`, `ConnectionLoss` (`Intent/App/AppCoordinatorConnectionScreen.swift`), `AppCoordinator.onScenePhaseBackground()` (`Intent/App/AppCoordinatorRouting.swift`)

## Context

After the user enters the remote UI, the transport can drop, reconnect, or
stop for good. The window must keep showing readable data, block only when
reconnection has stopped, and never flash blank metadata or stale losses.

## Decisions

### 1. Entry progress cannot be proven by old data

Applies to: `AppCoordinatorLifecycleState.Entry`, `AppCoordinator.establishConnectionLossEligibility()`

`Entry` tracks progress toward usable remote UI. `dataStamp` is workspace
data that predates the flow, so it cannot prove this flow fetched anything.
Only `.entered` lets a connection loss present the overlay.

`establishConnectionLossEligibility()` requires data fetched in this flow
(`lastUpdated != dataStamp`). A timed-out initial data wait still uses the
normal navigation fallback but cannot arm the blocking overlay. On entry the
connection observation restarts, which retires only the deliveries queued
before entry became usable.

### 2. Return Home is orthogonal to entry

Applies to: `AppCoordinatorLifecycleState.hasReturnedToSavedMachines`, `AppCoordinator.stopConnectionLifecycleForReturnHome()`, `resumeConnectionLifecycleIfNeeded()`

`hasReturnedToSavedMachines` is independent of `entry`. Once set, late
callbacks are ignored. `stopConnectionLifecycleForReturnHome()` retires
callbacks before the root releases the session: queued publisher deliveries
and old `ConnectingView` completions must not leave Home. Standalone
coordinators (tests, previews) reuse their connection on an explicit
saved-machine selection through `resumeConnectionLifecycleIfNeeded()`; the
live root creates a new one.

### 3. A new flow starts clean

Applies to: `AppCoordinator.resetConnectionLossEligibility()`, `AppCoordinator.workspaceDetailStores`

A new initial flow must not inherit a previous session's loss or delayed
recovery work. `workspaceDetailStores` keeps the window's recently viewed
workspace pages, readable during a drop. Leaving the remote UI (Home, Log Off,
switching Mac) drops those retained pages.

### 4. `ConnectionLoss` states

Applies to: `ConnectionLoss`, `AppCoordinator.connectionLoss`, `AppCoordinator.isDisconnected`, `AppCoordinator.endRecoveryWait(_:)`

`.lost` stays until the transport reconnects. `.recovering` then waits for
workspace data, or the overlay timeout, before clearing, so the UI never
flashes blank. Only the connection observer and recovery set `connectionLoss`.
Every write that leaves `.recovering` goes through `endRecoveryWait`, which
cancels the timeout and retires the one-shot workspace-loading registration.

`isDisconnected` is a loss recorded after entry that has not finished
recovering. Unlike the transport state, it stays true while reconnected data reloads.

### 5. The loading observation generation is tracked on purpose

Applies to: `AppCoordinator.reconnectLoadingObservationGeneration`, `observeWorkspaceLoading(observationID:)`

`reconnectLoadingObservationGeneration` is observed, not
`@ObservationIgnored`. Mutating it consumes the current one-shot
workspace-loading registration before that registration is abandoned.

### 6. Reconnection waits for workspace data

Applies to: `AppCoordinator.startObservingConnection()`, `waitForWorkspaceLoadThenClearOverlay()`

- On `.reconnecting` or `.disconnected`, a recovery in progress stops waiting and shows the loss again.
- On `.connected` after a loss, the overlay clears only after workspace data
  loads, so the UI does not flash blank metadata. The agent of an open
  conversation may have been deleted while disconnected, so it is
  re-validated. Workspace validation follows from the reconnect `fetchAll`.
- `waitForWorkspaceLoadThenClearOverlay()` first sets `.lost`, which cancels any
  observer from a prior reconnection attempt. If the store is not loading and
  `lastUpdated` is set, the data is already there and the loss clears. Otherwise
  it observes `isLoading` going from true to false (`fetchAll` completed).

### 7. Obsolete deliveries never present a loss

Applies to: `AppCoordinator.connectionDeliveryIsCurrent(_:)`

A loss and recovery burst can finish before either publisher delivery. The
obsolete loss is never presented, but the reconnect's agent check still runs.

### 8. Remote phase: read-only while reconnecting, blocked when stopped

Applies to: `RemoteConnectionPhase`, `AppCoordinator.remotePhase`, `isRemoteReadOnly`, `showsConnectionLossOverlay`, `showsReadOnlyBanner`

`RemoteConnectionPhase` says how the window's Mac connection is usable after
the user entered the app. An ordinary drop keeps everything readable. A
stopped reconnection blocks.

- `isDisconnected` records a loss after entry. The transport says whether
  reconnection is still trying (`.readOnly`) or has stopped for a reason
  (`reconnectStopReason` or certificate mismatches: `.stopped`).
- A plain `.disconnected` (a failed desktop startup, or a session shared
  during a repair) stays a banner: nothing says the user must act on Home.
- Change controls are disabled in every phase except `.live`, including the
  background grace when no banner is shown yet.
- `showsConnectionLossOverlay` is the blocking "Can't reconnect" screen, for
  reconnection that stopped for good. `showsReadOnlyBanner` is the non-blocking
  banner while reconnection keeps trying.

### 9. Background grace is presentation only

Applies to: `ConnectionLossPresentation`, `ConnectionLossPresentation.becameActive(onDeadline:)`, `recovered()`, `AppCoordinator.onScenePhaseBackground()`

`ConnectionLossPresentation` is presentation only. The transport state and the
coordinator's recovery and data gate stay authoritative. A background scene
cannot pre-present a new failure.

- At the grace deadline, `onDeadline` first reconciles a recovery whose
  publisher delivery is still queued, then any pending loss becomes visible.
- `recovered()` resets only in `.grace`. A recovery while backgrounded still
  needs protection for a loss queued at reactivation. A real recovery during
  grace retires the deadline.
- `onScenePhaseBackground()` is the only entry. Inactive alone (Control Center,
  permissions) is not a background return and must not delay an ordinary
  foreground connection failure. A loss already on screen (blocking or banner)
  stays put, so it is not eligible for deferral.

### 10. Connection screens

Applies to: `ConnectionScreen`, `AppCoordinator.connectionScreen`, `AppCoordinator.connectingStartedByLaunch`

`ConnectionScreen` holds the fields only the connection screens read.
`.loading` and `.connecting` share one splash, so both use `.connecting`;
every other screen is `.other`. `AppCoordinator.currentScreen` keeps the case
in step with the screen.

- `connecting(startedByLaunch:)`: launch or restoration auto-connect uses the
  launch artwork and hides Connecting's Back action until startup needs it.
  Only that case hides the Back action.
- `pairing(showsSavedConnections:)`: Connect to… offers the other saved
  connections, for example after logging off one connection while others are
  still saved.

### 11. Connection attempts are keyed

Applies to: `AppCoordinator.connectionAttemptId`, `restartConnectionAttempt()`, `routeToConnectionFailure(error:retryPolicy:)`

`connectionAttemptId` keys `ConnectingView`'s one-shot connection-attempt
task. `onSwitchConnection` bumps it through `restartConnectionAttempt()`, so a
switch made while `currentScreen` is already `.connecting` (for example a
deep-link pairing confirmed over the cold-start connect) restarts the attempt.
SwiftUI would otherwise keep the existing `ConnectingView` and never re-run its
task. `restartConnectionAttempt()` keeps the transition order.
`routeToConnectionFailure` applies retry ownership before it shows the failure screen.

### 12. Read-only navigation uses the last confirmed person

Applies to: `AppCoordinator.canUseAssistant`, `AppCoordinator.shouldDismissWorkspaceCreation`

A drop clears the live principal, so read-only navigation falls back to the
person last confirmed. Mutation checks keep using the live principal.
Temporary transport recovery keeps the workspace creation draft while
submission stays gated. An authority invalidation, a demotion, or a final
disconnect closes it.

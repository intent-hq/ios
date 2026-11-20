# 0071. Connection screens, connection loss and recovery

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

A window connects through a launch splash, then shows remote data. The transport can drop and reconnect at any time, including in the background. Publisher deliveries can arrive late, after the state they describe has changed. Reconnected data loads after the socket is back, so the UI can show blank metadata in between.

## Decision

1. **Connection screens.**
   1. Loading and connecting share one splash (`ConnectionScreen.connecting`). One `SplashArtView` stays in a stable position across both, so its animation does not reset.
   2. Only launch or restoration auto-connect hides Connecting's Back action (`connectingStartedByLaunch`).
   3. The pairing screen offers the remaining saved connections, including synced ones, whenever any exist.
2. **Entry.**
   1. A loss can show the overlay only after the user entered the remote UI (`AppCoordinatorLifecycleState.Entry.entered`).
   2. Eligibility needs workspace data fetched in this flow. Data from before the flow does not count (`dataStamp`). A timed-out initial wait uses the normal navigation fallback but cannot arm the overlay (`establishConnectionLossEligibility()`).
   3. A new initial flow never inherits an earlier loss or delayed recovery work (`resetConnectionLossEligibility()`). Entry retires only deliveries queued before entry.
   4. Returning Home retires callbacks before the session is released, so queued deliveries and old Connecting completions cannot act on Home.
3. **Loss and recovery** (`ConnectionLoss`).
   1. `.lost` stays until the transport reconnects. `.recovering` then waits for workspace data, or the overlay timeout, before it clears, so the UI never flashes blank metadata.
   2. `isDisconnected` stays true while reconnected data reloads.
   3. Only the connection observer and recovery set `connectionLoss`. Every write that leaves `.recovering` goes through `endRecoveryWait(_:)`.
   4. A loss and recovery burst that ends before either delivery is never shown, but the reconnect still revalidates the open agent.
4. **Remote phase** (`RemoteConnectionPhase`).
   1. An ordinary drop keeps everything readable. Change controls are disabled in every phase except live (`isRemoteReadOnly`), including the background grace with no banner yet.
   2. While reconnection keeps trying, a non-blocking banner shows. When it stops for a reason (`reconnectStopReason`), a blocking "Can't reconnect" screen shows.
   3. A plain `.disconnected` (a failed desktop startup, or a session shared during a repair) stays a banner.
5. **Identity during a drop.** Read-only navigation uses `lastConnectedPrincipal`. Authority and mutation checks use only the live principal.
6. **Workspace creation during a drop.** Temporary transport recovery keeps the creation draft and keeps submission gated. An authority invalidation, demotion or final disconnect closes it (`shouldDismissWorkspaceCreation`).
7. **Background** (`ConnectionLossPresentation`).
   1. Presentation is not authority: the transport state and the coordinator's recovery gate decide.
   2. Only a background scene phase starts the grace. Inactive alone (Control Center, permission prompts) never delays a foreground failure.
   3. A loss already on screen stays when the app goes to the background.
   4. On return, a queued recovery is reconciled before any pending loss shows. A real recovery during grace retires the deadline.
8. **Startup fallback.** The initial workspace-data wait stays bounded, even during transport-owned reconnect. Routing completion alone does not make the overlay eligible (`onInitialWorkspaceLoadComplete(attemptID:)`).
9. **Global subscription.** A live socket without its global event subscription leaves stores blind. After bounded retries, `globalSubscriptionState` is `.failed` and the window shows a retry routed to `retryGlobalSubscription()` (ios#254).

## Consequences

- The overlay never flickers for a short drop, and never shows before the user had real data.
- New code that leaves `.recovering` must call `endRecoveryWait(_:)`.

## Code

- `AppCoordinator`: `connectionLoss`, `isDisconnected`, `connectingStartedByLaunch`, `endRecoveryWait(_:)`, `establishConnectionLossEligibility()`, `resetConnectionLossEligibility()`, `stopConnectionLifecycleForReturnHome()`, `waitForWorkspaceLoadThenClearOverlay()`, `shouldDismissWorkspaceCreation`, `onScenePhaseBackground()`, `onInitialWorkspaceLoadComplete(attemptID:)`
- `AppCoordinator`: `remotePhase`, `isRemoteReadOnly`, `showsConnectionLossOverlay`, `showsReadOnlyBanner`
- `ConnectionScreen`, `ConnectionLoss`, `RemoteConnectionPhase`, `AppCoordinatorLifecycleState`
- `ConnectionLossPresentation`: `enteredBackground(eligible:)`, `becameActive(onDeadline:)`, `recovered()`
- `SessionConnectionManaging`: `lastConnectedPrincipal`, `globalSubscriptionState`, `reconnectStopReason`

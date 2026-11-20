# 0045. Connecting and connection-failure screens

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

A window shows a splash while it loads and connects, then the workspace list. A connect can fail, be cancelled by a newer attempt, or race a connection switch. The failure screen can retry by itself. ADR 0070 owns window binding and ADR 0071 owns connection loss; this record covers the screens.

## Decision

1. **Splash.**
   1. `RootView` draws the splash art in one position for the loading and connecting phases, so playback does not reset between them. `LoadingView` and `ConnectingView` are overlays.
   2. `LoadingView` advances to connecting after a fixed 1.2 s beat. It does not wait for the twist intro to finish.
   3. `SplashArtView` holds its `SplashAnimationLease` only for its lifetime, so the decoded compositions go away with the splash (ios#256).
   4. The existing monotonic clock is the only playback driver. Lottie never starts its own animation, so nothing plays while the scene is inactive (`SplashFrameView`).
   5. The splash image honours the SwiftUI size proposal, not the 256-point intrinsic size (ios#475).
   6. `IntentLogo` matches the desktop `Logo.svelte` vector in its 24×24 viewBox.
   7. `DaemonStartupProgressView` is shared by the initial connection and the reconnection surface. Its counts are exact. A daemon time estimate applies only to indexing, never to readiness.
2. **Attempt ownership.**
   1. `ConnectingView` runs its attempt in `.task(id: coordinator.connectionAttemptId)`. A connection switch while the screen shows bumps the id and restarts the attempt.
   2. A cancelled or superseded attempt never routes. Its failure and its success must not replace the screen that the newer attempt, or the connected UI, owns (ios#230). This applies to the loading beat, the connect, and the wait for workspace data.
   3. `failureOutcome(for:replacedByNewerAttempt:)`: a cancellation is never a connection failure. If a newer connect replaced it (for example a pairing or invite link moved the window to another host), the screen is left to that attempt. If no successor exists (sync refreshed the saved login or route during startup admission), the attempt retries with the refreshed record, so the window never stays on Connecting. A failed daemon startup is already shown by the startup screen.
   4. If the window's saved connection was deleted, the window root's removal observation closes or rebinds the window.
   5. After connecting, the screen waits for `WorkspaceStore.lastUpdated`, with a timeout, so the user never sees an empty workspace list and never gets stuck on the splash.
   6. Demo and screenshot launches have no daemon. In Debug, `connectDemoSessionIfRequested()` marks the connection live so the stores read fixtures.
3. **Certificate mismatches.**
   1. `CertMismatchListView` is passive and has no actions. It shows one row per host with the fingerprint that host presented: while connecting (other hosts keep racing), on the re-pair screen (every mismatching host, not only the last), and in connection details while a stale sibling route still mismatches.
   2. A row truncates a SHA-256 fingerprint to its leading bytes with an ellipsis. Short values pass through.
   3. `isCertificateMismatchMessage(_:)` matches, case-insensitively, "Certificate fingerprint mismatch", "Server certificate has changed" and "No trusted certificate is saved". All three route to the certificate path: no auto-retry, a "Re-pair Device" action, and the saved record is kept.
4. **Auto-retry.**
   1. The failure screen dials only this window's own bound record, re-read on each attempt so a token rotated by sync is used. It never dials the global pairing record. If the record is gone, it routes to pairing.
   2. A failed Log Off (`.manualLogOff`) never auto-retries. "Retry Disconnect" retries forgetting the record; it does not reconnect (ios#235). Certificate failures go to re-pairing.
   3. Backoff is 2 s, 4 s, 8 s, 16 s, then 30 s.
   4. A cancelled retry never routes: the user may have switched connections, and a late success would restore the failing daemon.
   5. Home retires the coordinator before SwiftUI cancels the view's retry task, so the retry checks `hasReturnedToSavedMachines` first.
   6. `runAutoRetry` is independent of the view, so tests drive it with a coordinator and a fake connection.
   7. Alternative connections are the other saved connections, most recently used first.
5. **Content missing during a drop.** `AvailableWhenReconnectedView` replaces a loading state or an error when the app has no copy of the content and the connection is lost. It has no Retry: the owning screen reloads by itself on reconnect (`onReconnect(_:)`).

## Code

- `LoadingView`, `ConnectingView`: `failureOutcome(for:replacedByNewerAttempt:)`, `FailureOutcome`, `connectDemoSessionIfRequested()`
- `SplashArtView`, `SplashFrameView`, `SplashAnimationLease`, `IntentLogo`, `DaemonStartupProgressView`
- `CertMismatchListView`: `displayFingerprint(_:maxBytes:)`
- `ConnectionFailureView`: `isCertificateMismatchMessage(_:)`, `autoRetryConnection`, `alternativeConnections`, `shouldAutoRetry`, `retryBackoff(attempt:)`, `runAutoRetry`
- `AvailableWhenReconnectedView`, `availableWhenReconnected(isMissing:isCompact:)`

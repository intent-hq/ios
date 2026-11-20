# ADR-1217: Loading and connecting screens

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `LoadingView`, `IntentLogo` (`Intent/Views/Connection/LoadingView.swift`), `ConnectingView` (`Intent/Views/Connection/ConnectingView.swift`), `CertMismatchListView` (`Intent/Views/Connection/CertMismatchListView.swift`), `DaemonStartupProgressView` (`Intent/Views/Connection/DaemonStartupProgressView.swift`)
- Related issues: ios#230

## Decisions

### 1. RootView owns the splash art for both phases

Applies to: `LoadingView`, `ConnectingView`

The splash artwork is rendered by `RootView` in a position shared by the
loading and connecting phases, so playback does not reset on the loading →
connecting transition. `LoadingView` only owns the launch timer that advances
the coordinator independently of animation completion. `ConnectingView`
presents passive per-host certificate-mismatch warnings and owns the connection
attempt.

### 2. The loading phase is a fixed beat

Applies to: `LoadingView.body`

The view advances to connecting after `Constants.Loading.phaseDuration`
(1.2 seconds). The phase is not lengthened to wait for the twist intro to
finish; playback continues uninterrupted.

### 3. A cancelled attempt never routes the screen

Applies to: `LoadingView.body`, `ConnectingView.connectSavedMachine()`, `ConnectingView.attemptConnection()`

When the view goes away before its beat or wait ends, or the attempt is
restarted, the superseded timeline must not advance the coordinator or publish
success over whatever replaced it (ios#230). A bumped `connectionAttemptId`
cancels the task and starts a replacement; the superseded attempt's failure
must not overwrite the screen that the restarted attempt (or the connected UI)
owns. A connect starts one attempt, so a higher `connectAttemptCount` means a
later attempt replaced it.

### 4. The attempt task is keyed on `connectionAttemptId`

Applies to: `ConnectingView.body`

A connection switch made while this view is already showing (same screen value)
bumps the id to restart the attempt. A plain one-shot `.task` would not.

### 5. Failure outcomes

Applies to: `ConnectingView.FailureOutcome`, `ConnectingView.failureOutcome(for:replacedByNewerAttempt:)`

A cancellation is never a connection failure, so its "CancellationError" text
never shows.

- `leave`: another owner routes the screen. This is the outcome when a newer
  connect on this session replaced the attempt (for example a pairing or invite
  link moving this window to another host), and when the daemon startup failed,
  which the startup screen already shows.
- `retry`: cancelled with no successor (sync refreshed the saved login or
  route during startup admission). Connect again with the window's current
  saved record, so the window is never left on Connecting.

### 6. A deleted saved connection is reported, not dialed

Applies to: `ConnectingView.connectSavedMachine()`

`connectSavedMachine()` returns false when the attempt ended (failure routed,
superseded, or no saved connection). When the bound backend's saved connection
was deleted out from under the window, the view reports a failure; the window
root's removal observation closes or rebinds the window.

### 7. One Debug seam

Applies to: `ConnectingView.connectDemoSessionIfRequested()`

This is the view's single Debug seam. Demo and screenshot launches have no
daemon, so it marks the connection live and lets the stores fetch from fixtures.

### 8. Certificate mismatch list

Applies to: `CertMismatchListView`, `CertMismatchListView.displayFingerprint(_:maxBytes:)`

The list is passive and purely informational, with no actions: one row per host
with the fingerprint the host actually presented. It is rendered while
connecting or reconnecting (the race continues on the remaining hosts), on the
cert-mismatch re-pair screen (every mismatching host, not just the last one),
and as a non-blocking indicator in the connection details while connected via a
route that still has stale mismatching siblings. `displayFingerprint` truncates
a colon-separated SHA-256 fingerprint (32 bytes) to its leading bytes with an
ellipsis so a row stays on one line; short values (for example test fixtures)
pass through unchanged.

### 9. Daemon startup progress

Applies to: `DaemonStartupProgressView`

The view is shared by initial connection and the scene-covering reconnection
surface. Counts are exact; any daemon estimate applies only to indexing, not to
readiness.

### 10. Intent logo vector

Applies to: `IntentLogo`

The Intent burst mark matches cloudlands-fe's `Logo.svelte` vector. The
original viewBox is 0 0 24 24.

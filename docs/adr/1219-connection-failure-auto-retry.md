# ADR-1219: Connection failure screen and auto-retry

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConnectionFailureView`, `FailurePageLayout` (`Intent/Views/Connection/ConnectionFailureView.swift`)
- Related issues: ios#235

## Decisions

### 1. Auto-retry dials only this window's bound record

Applies to: `ConnectionFailureView.autoRetryConnection(connections:windowConnectionID:)`, `ConnectionFailureView.runAutoRetry`

Auto-retry dials this window's own bound connection, resolved from the saved
list, never the global pairing record. A retry success then reconnects this
window's backend instead of retargeting it at the last-used one (window model
v2). Nil (an unbound window, or a record deleted mid-failure) means there is
nothing to dial, and the screen routes to pairing instead of dialing another
backend's record. The record is re-read on each attempt, so rotated tokens
synced mid-retry are used.

### 2. When the screen may retry on its own

Applies to: `ConnectionFailureView.shouldAutoRetry(retryPolicy:isCertMismatch:)`

A failed Log Off (`.manualLogOff`) never retries on its own: the user asked to
disconnect, so re-establishing the session must be an explicit action. "Retry
Disconnect" retries forgetting the record; it does not reconnect (ios#235).
Certificate failures route to re-pairing.

### 3. Backoff

Applies to: `ConnectionFailureView.retryBackoff(attempt:)`

Exponential backoff: 2s, 4s, 8s, 16s, with a maximum of 30s.

### 4. The retry loop is independent of the view

Applies to: `ConnectionFailureView.runAutoRetry`

The loop is a static function so tests can drive it against a coordinator and a
fake connection. It returns without dialing when `shouldAutoRetry` is false.
Otherwise it loops until a dial succeeds (routes via `onConnectionSuccess`),
the bound record disappears (routes to pairing), or the task is cancelled.

### 5. Home and cancellation stop routing

Applies to: `ConnectionFailureView.runAutoRetry`

Home retires the coordinator synchronously, before SwiftUI delivers
`onDisappear` and cancels the view-owned retry task, so the loop checks
`hasReturnedToSavedMachines`. A cancelled retry never routes: the user may have
switched to another saved connection while the connect was in flight, and a
stale success would restore the failing daemon over the selected one.

### 6. Alternatives list

Applies to: `ConnectionFailureView.alternativeConnections(connections:activeId:)`

Alternatives are the saved connections other than this window's failing bound
one, most recently used first.

### 7. Layout

Applies to: `ConnectionFailureView`, `FailurePageLayout`

The 48pt export hit target includes space below its text, so the page ignores
the bottom container safe area; the visible label stays above the home
indicator and matches the mock's inset. `IntentButtonStyle` adds 12pt above and
below the label. `FailurePageLayout` centers the main group when space permits
and keeps help at the bottom without overlap. In the scroll view, a taller
intrinsic size makes every section reachable.

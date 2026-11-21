# ADR-0079: LoadPhase keeps the last success on screen through failed refreshes

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `LoadPhase` (`Intent/Services/LoadPhase.swift`)
- Related issues: ios#462

## Context

`LoadPhase` describes one finite list read (ios#462): not started, running,
succeeded, or failed before any success.

## Decisions

### 1. A failed refresh keeps the last success

Applies to: `LoadPhase.failing(_:)`, `LoadPhase.failingVisibly(_:)`

When a refresh fails after a success, cached rows stay on screen. They are not
replaced by an error.

### 2. Case meanings

Applies to: the cases of `LoadPhase`

1. `failed`: the latest read failed and none has succeeded since the last
   reset.
2. `loading(lastLoadedAt:)`: a read is running. `lastLoadedAt` is the success
   that is still shown meanwhile.
3. `loadingKeepingFailure`: a read is running and the last failure stays on
   screen until it ends (Retry, or an event refresh after a failure). Only
   `beginningKeepingFailure()` and `failingDuringRead(_:)` produce it. The read
   ending restores the failure.
4. `refreshFailed`: a read failed after a success. The shown data stays and so
   does the message, until the next read starts. Only `failingVisibly(_:)`
   produces it.

### 3. What views show for each failure accessor

Applies to: `LoadPhase.failureMessage`, `LoadPhase.refreshFailureMessage`,
`LoadPhase.isAwaitingFirstLoad`

1. `failureMessage` is a failed first read. Views show `LoadFailureView` with
   Retry.
2. `refreshFailureMessage` is a failed refresh shown over the kept data.
3. `isAwaitingFirstLoad` means no data and no failure yet. Views show their
   loading placeholder.

### 4. Transitions return the next phase

Applies to: `beginning()`, `beginningKeepingFailure()`, `failingDuringRead(_:)`,
`failing(_:)`, `failingVisibly(_:)`, `clearingFailure()`, `settled()`

Transitions return the next phase instead of mutating, so stores assign only
real changes. An identical refetch must not invalidate observers.

1. `beginningKeepingFailure()` starts a read that leaves a shown failure on
   screen until the read ends.
2. `failingDuringRead(_:)` records a failure while the read keeps running (a
   pass with a trailing pass, or a page that keeps loading). The read ending
   shows it.
3. `clearingFailure()` dismisses a shown failure without starting a read.
4. `settled()` ends a read that produced no result (cancelled or superseded). A
   kept failure stays.

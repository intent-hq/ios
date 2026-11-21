# ADR-0102: Parked callers resume individually and never cancel the shared operation

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceAuthorityGate` (`Intent/Services/WorkspaceAuthorityGate.swift`),
  `WorkspaceStatusWaiters` (`Intent/Services/WorkspaceStatusWaiters.swift`)

## Context

Several reads must wait for a value that another operation resolves. These two
types park callers until that value is known.

## Decisions

### 1. `WorkspaceAuthorityGate` parks reads until the workspace is authoritative

Applies to: `WorkspaceAuthorityGate`, `WorkspaceAuthorityGate.wait()`,
`WorkspaceAuthorityGate.clearFailure()`

Some reads need an agent's authoritative workspace while only a route hint is
known. The gate parks them. Shared agent detail either resolves the workspace or
fails. A failure refuses later waits, and it owes the subscriptions a fresh read
once the workspace resolves.

`wait()` returns true when the workspace resolves, and false on failure,
cancellation, or reset. `clearFailure()` clears a failure without releasing
waiters, and returns whether a failure was cleared.

### 2. `WorkspaceStatusWaiters` lets one shared operation outlive any caller

Applies to: `WorkspaceStatusWaiters`

One shared operation can outlive any caller. Cancelling a waiter resumes only
that caller. It never cancels the registration or another consumer.

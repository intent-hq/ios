# ADR-0056: BackgroundHookStore leases the shared hook cache and folds hook events

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `BackgroundHookStore` (`Intent/Services/BackgroundHookStore.swift`)

## Context

Conversations show the background hooks of their workspace. The hook list is
cached per session in a `WorkspaceStatusStore` and updated from `hook:*` events.

## Decisions

### 1. The store is a conversation's lease on a session-owned cache

Applies to: `BackgroundHookStore`, `BackgroundHookStore.subscribe(workspaceId:agentId:)`

Each `BackgroundHookStore` is one conversation's lease on the session-owned
workspace hook cache. It does not own the rows.

### 2. Hook actions are acknowledged; results arrive as events

Applies to: `BackgroundHookStore.runNow(hookId:)`, `BackgroundHookStore.cancel(hookId:)`

`hook.runNow` (§5.40) returns an ack only. The run's outcome arrives as `hook:*`
events. After `hook.cancel` (§5.40), the `hook:cancelled` event drops the hook.

### 3. Hook events fold into the list as in the frontend

Applies to: `BackgroundHookStore.foldHookEvent(hooks:eventType:data:)`

The fold is pure and matches cloudlands-fe's `foldHookEvent`.

1. Terminal events (`hook:dispatched`, `hook:evicted`, `hook:cancelled`,
   `hook:expired`) drop the hook.
2. An event for a hook that the list has never seen sets `needsRefetch`. The
   fold cannot invent the missing wire fields (`delayMs`, `createdAt`), so the
   caller re-runs `hook.list` to converge.
3. On `hook:run-completed`, a present `nextRunAt` means the hook stays
   scheduled. An absent `nextRunAt` means a terminal dispatched or evicted
   event follows and drops it (§6.5).

### 4. Late list replies never undo removals or unsubscribe

Applies to: `BackgroundHookStore.subscribe(workspaceId:agentId:)`, `BackgroundHookStore.unsubscribe()`

A `hook.list` reply that was in flight never brings back a hook that a later
event removed, and never refills a list that `unsubscribe()` cleared. A
complete cancellation event replays over a stale seed without a recovery read.

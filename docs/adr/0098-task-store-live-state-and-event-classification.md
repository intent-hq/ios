# ADR-0098: TaskStore live state and task event classification

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `TaskStore` (`Intent/Services/TaskStore.swift`)

## Context

`TaskStore` holds the task list of one workspace. It reads `task.list`, keeps
the list live with `task.subscribe`, and falls back to legacy `task:*` events.
Its live-state handling follows the same pattern as `NoteStore` (ADR-0085).

## Decisions

### 1. Full list read

Applies to: `TaskStore._fetchAll()`

`task.list` without `limit` or `nextToken` answers the whole list. If a reply
carries `nextToken` anyway, every page is read before publishing, and a failed
page keeps the previous list (bounded reads).

### 2. Reconnect and handler lifecycle

Applies to: `TaskStore.onConnected()`, `TaskStore.subscribeToEvents()`, `TaskStore.deinit`

1. `onConnected` resets live-state tracking and unregisters the old handler,
   because a subscription is invalid after a disconnect.
2. `subscribeToEvents` removes the old handler first, so handlers do not
   accumulate on reconnect.
3. `deinit` removes handlers directly, because it is isolated to the
   MainActor.

### 3. Live subscription

Applies to: `TaskStore.subscribeLiveState(generation:)`, `TaskStore.handleSubscriptionPush(_:)`,
`TaskStore.fillSnapshot(reconciler:firstToken:)`, `TaskStore.resnapshot()`, `TaskStore.snapshotFiller`

1. If the server does not support `task.subscribe`, the error response falls
   back to legacy events.
2. The push handler is registered in the same MainActor tick as the
   acknowledgement, which keeps the sync-capture guarantee.
3. The reconciler is created synchronously before the subscribe request, so a
   push that arrives between the request and its response is safe to process.
   A push is processed only when a reconciler exists.
4. `ConnectionManager` routes pushes by subscription id at the transport layer,
   so the handler receives only pushes for this store's subscription id. No
   per-store gate is needed; the router is the single source of truth.
5. While a paged snapshot is still filling, deltas do not publish; the list
   publishes once the fill completes.
6. A sequence gap starts a resnapshot. `LiveSubscription.requestResnapshot()`
   guards against a storm.
7. `snapshotFiller` reads the rest of a paged `task.subscribe` snapshot
   (§6.9). `fillSnapshot` uses the paged `task.list` (`WorkspaceTask` rows,
   which parse like the snapshot's task notes), then publishes the whole list.
   The previous list stays visible meanwhile. A walk that gives up shows what
   it has, unless that would shrink the list, and then resubscribes.
8. `resnapshot()` unregisters the handler before it sends `task.unsubscribe`.
   After resubscribing, it runs a baseline refetch to bridge the gap.

### 4. Legacy event handling

Applies to: `TaskStore.handleEvent(_:params:)`

1. `handleEvent` also parses `subscription.push`, for test injection
   compatibility.
2. Events from the websocket event bridge are wrapped as
   `{ subscriptionId, event: { type, workspaceId, timestamp, data } }`.
3. `task:*` events are scoped to this workspace, to avoid cross-workspace
   refetches.
4. The refetch runs only in the non-live fallback (no `task.subscribe`
   snapshot yet, or after a subscription loss). While live, deltas arrive
   through the subscription push, and a refetch would double-apply.

### 5. Event classification tables

Applies to: `TaskStore.handledChannels`, `TaskStore.refetchEventTypes`, `TaskStore.ignoredEventTypes`,
`TaskStore.readyTasksChangedReasonClassification`, `TaskStore.readyTasksChangedWithoutReason`,
`TaskStore.classify(type:data:)`

1. `handledChannels` lists the bus channels this store consumes. Every catalog
   type on them must be in exactly one table
   (`IntentTests/EventCatalogCoverageTests.swift`).
2. `refetchEventTypes` is an explicit allowlist, like `AgentStore` and
   `WorkspaceStore`. Only events that can change a field a `WorkspaceTask` row
   renders (id, title, status, updatedAt) or list membership refetch
   `task.list`. `task:created` changes membership; `task:status-changed`
   changes status and updatedAt.
3. `ignoredEventTypes`: `task:agent-linked` and `task:agent-unlinked` are
   ignored on purpose, because the assignee is not part of the row. Task body
   and title edits ride `note:updated`, not `task:*`, so they never reach this
   store.
4. `task:ready-tasks-changed` is classified per `data.triggeredBy.reason` (the
   golden's `discriminators` entry for this type). Readiness is not rendered,
   so `relations-changed` emissions carry no rendered field. The exception is
   `note-deleted`: intentd's `delete_note` emits no other `task:*` type (only
   `note:deleted`, which this store does not receive), so that emission is the
   only `task:*` signal that a row left the list.
5. The status-change emission has no `reason` (`triggeredBy` is
   `{ noteId, previousStatus, newStatus }`). It always pairs with a
   `task:status-changed` that already refetches, so it is ignored.
6. `classify` returns nil when the tables do not name the type (or, for
   `task:ready-tasks-changed`, the reason). `handleEvent` treats nil as
   ignore.
7. `classify` takes optional event data, because the shared classifier
   signature accepts absent event data without inventing a payload.

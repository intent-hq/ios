# ADR-0059: CommentStore follows a live `comment.subscribe` feed

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `CommentStore` (`Intent/Services/CommentStore.swift`)

## Context

`CommentStore` shows the comment threads of the open note. It subscribes with
`comment.subscribe`, applies snapshot and delta pushes through a
`DeltaReconciler`, and resubscribes on gaps and reconnects.

## Decisions

### 1. Reconnect drops the old subscription before resubscribing

Applies to: `CommentStore.onConnected()`

A subscription is invalid after a disconnect. On a new connection the store
bumps its generation, unregisters the old handler, clears the reconciler and
cancels the snapshot filler, then resubscribes to the open note.

### 2. The reconciler exists before the subscribe RPC is sent

Applies to: `CommentStore.subscribeLiveState(workspaceId:noteId:generation:)`,
`CommentStore.handleSubscriptionPush(_:)`

The reconciler is created synchronously before `comment.subscribe` is sent.
A push that arrives between the request and its response is therefore safe to
process. Pushes are ignored only when no reconciler exists.

### 3. The push handler is registered in the same main-actor tick as the ack

Applies to: `CommentStore.subscribeLiveState(workspaceId:noteId:generation:)`

The handler is registered immediately after the subscription id is
acknowledged, in the same `MainActor` tick. This preserves the sync-capture
guarantee.

### 4. The router owns per-subscription delivery

Applies to: `CommentStore.handleSubscriptionPush(_:)`

`ConnectionManager` routes pushes by subscription id at the transport layer.
The handler only receives pushes for its own subscription, so the store has no
per-store gate. The router is the single source of truth.

### 5. Paged snapshots are filled with `comment.list`

Applies to: `CommentStore.snapshotFiller`, `CommentStore.fillSnapshot(reconciler:firstToken:)`

`snapshotFiller` reads the rest of a paged `comment.subscribe` snapshot
(protocol §6.9) with `comment.list`, then publishes every thread. Only the
summary fields are read. They describe the whole thread even when the daemon
trims a large thread's `comments` (`commentsTruncated`), so no
`comment.getThread` is needed. A walk that gives up shows what it has, unless
that would shrink the list, and then resubscribes. While a paged snapshot is
still filling, deltas are applied but published only once it completes.

### 6. A sequence gap resnapshots, guarded against storms

Applies to: `CommentStore.handleSubscriptionPush(_:)`, `CommentStore.resnapshot()`

A delta that does not apply means a gap. The store resubscribes only when
`LiveSubscription.requestResnapshot()` allows it, so a burst of gaps does not
start a storm of resubscriptions.

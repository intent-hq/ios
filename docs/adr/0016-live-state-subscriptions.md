# 0016. Live-state subscriptions and single-flight reads

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Stores follow daemon state through `*.subscribe` and `subscription.push` (protocol §6), or through bus events. Reads can overlap with events and reconnects. Many stores need one read in flight and a bounded catch-up.

## Decision

1. **Single-flight reads (`CoalescedRead`).**
   1. An invalidation during a run earns at most one trailing pass. Later invalidations leave the read dirty, and `run` returns true to its owner.
   2. A caller that ignores the result waits for the next explicit read, event or reconnect, so a noisy feed cannot loop it.
   3. A caller that runs again on true opts into "repeat until settled" and owns that loop. Only an invalidation during the last pass earns another run. `cancel()` ends it.
   4. `isCurrent` is checked before every pass.
2. **Event classification.** Each store has a pure `classify(type:data:)` that returns an `EventClassification` or nil for a type its tables do not name. `EventCatalogCoverageTests` proves every type intentd emits on the store's channels is a deliberate decision. `refetch` is only for the non-live fallback.
3. **Subscribe order.**
   1. The store creates its `DeltaReconciler` synchronously, before the subscribe RPC. A push that arrives between the request and the reply is then safe to apply.
   2. The push handler is registered in the same main-actor tick as the reply, so no push is lost.
   3. `ConnectionManager` routes pushes by `subscriptionId` at the transport layer. A store's handler gets only its own pushes; there is no per-store gate.
4. **Gaps and snapshots.**
   1. A sequence gap starts a resnapshot. `LiveSubscription.requestResnapshot()` guards against a resnapshot storm.
   2. A paged snapshot (§6.9) publishes once it is complete.
   3. `CommentStore.fillSnapshot(…)` reads the rest of a paged snapshot with `comment.list`. Summary fields describe the whole thread even when the daemon trims `comments` (`commentsTruncated`), so no `comment.getThread` is needed. A walk that gives up shows what it has unless that would shrink the list, then resubscribes.
5. **Push parsing.** `SubscriptionPush` is nonisolated so `parse(method:params:)` runs in the off-main inbound frame parse (`ConnectionManager.parseInboundFrame`). Chat payloads are pre-decoded there (`snapshotMessages`, `DeltaPayload.chatBlocks`), so the main actor only merges. It is `@unchecked Sendable` because its dictionaries are parsed JSON that is never mutated. Chat block entities decode in one `ContentBlock.decodeBatch` pass (ios#258), with the same result as decoding each entity.
6. **Paged snapshot rows (`DeltaReconciler`).**
   1. `nextToken` is the list-read token for rows after the first page, or nil when the snapshot is whole (§6.9).
   2. Ids a delta or local seed changed since the snapshot are newer than any later page row; ids a delta removed must not be re-added by a page. `epoch` advances on every snapshot and reset, so a stale page walk sees it was superseded.
   3. `fillFromPage(_:)` skips those rows and upserts the rest. A walk that serves a row twice keeps the later one.
   4. `seed(id:value:)` puts new ids at the front and keeps existing positions, without touching sequence tracking. `patch(id:_:)` changes an existing row only; while a snapshot fills, an unread row comes from its page.

## Consequences

- A store that ignores `CoalescedRead.run`'s result can show stale data until the next trigger.
- Store races (from test comments): a resnapshot parked on its unsubscribe sees that the connection generation advanced and does not open a duplicate subscription over the new connection. A reconnect clears the resnapshot guard. A superseded ack is released on the daemon at once and never registered locally; two racing connects that get one id register it once.
- `NoteStore` workspace switches (ios#996): a switch subscribes the new workspace once, without waiting for a reconnect. A late ack for the old workspace is released. A → B → A ends with one subscription for the last workspace. A store whose connect handler ran before it had a workspace subscribes from `fetchNotes(workspaceId:)`, and a connect delivery queued in the same main-queue window does not reset that subscription. The generation fence alone stops a superseded switch back to the same workspace.

## Code

- `CoalescedRead`: `invalidate()`, `run(…)`, `settleScheduled()`, `cancel()`
- `EventClassification`
- `SubscriptionPush`: `parse(method:params:)`, `nextToken`; `DeltaReconciler`: `fillFromPage(_:)`, `seed(id:value:)`, `patch(id:_:)`, `epoch`
- `CommentStore`: `subscribeLiveState(workspaceId:noteId:generation:)`, `handleSubscriptionPush(_:)`, `fillSnapshot(reconciler:firstToken:)`
- `LiveSubscription`: `requestResnapshot()`
- `ConnectionManager`: `registerSubscriptionHandler(id:handler:)`

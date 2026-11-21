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
7. **`LiveSubscription` state.** One enum replaces the acknowledged id, a "live" flag and a resnapshot guard that each store kept side by side; every combination is a case, and stores change it only through named transitions.
   1. The id is the subscription whose push handler the store registered. During a resnapshot it is the old id while `*.unsubscribe` runs, nil while resubscribing, and the new id once acknowledged.
   2. `acknowledge(_:)` keeps the feed and any running resnapshot, and returns the previous id. The caller unregisters that handler, even when it equals the new id.
   3. `requestResnapshot()` returns false while a resnapshot runs; the feed changes only when the resnapshot body starts. `endResnapshot()` is a no-op after a teardown ended it.
   4. A store refetches on events only while not live, to avoid double application. During a resnapshot, a baseline refetch bridges the gap.
8. **`LoadPhase` (ios#462).** One finite list read: not started, running, succeeded, or failed before any success. A failed refresh keeps the last success, so cached rows stay instead of an error. A failed first read shows `LoadFailureView` with Retry.
   1. `loadingKeepingFailure` keeps a shown failure on screen until the read ends (Retry, or an event refresh after a failure). Only `beginningKeepingFailure()` and `failingDuringRead(_:)` produce it.
   2. `refreshFailed` keeps the data and the message until the next read starts. Only `failingVisibly(_:)` produces it.
   3. `failingDuringRead(_:)` records a failure while the read continues (a trailing pass, or more pages); the end of the read shows it. `settled()` ends a read with no result and keeps a kept failure.
   4. Transitions return the next phase, so stores assign only real changes and an identical refetch does not invalidate observers.
9. **Bounded reads (`PagedReads`, `server.capabilities.boundedReads: 1`).**
   1. A bounded daemon answers list reads one page at a time with an opaque `nextToken` (`null` on the last page). It sends a collection snapshot's first page with `params.nextToken` and cuts a very large note in `note.get` with `contentTruncated`/`nextContentOffset`. Older daemons ignore `limit`, `nextToken` and `contentOffset` and answer in one reply, so every walk ends after one request.
   2. Page sizes are the daemon maximums (`notePageLimit`, `commentPageLimit`, `workspacePageLimit`, `agentPageLimit`, `queuePageLimit`, `taskPageLimit`). `maxPages` stops any walk, so a misbehaving daemon cannot loop forever.
   3. `requestAllPages(…)` and `requestWholeReply(…)` repeat `params` with each token. Page errors propagate, a continuation page without the field throws `MalformedPage`, and a walk that cannot reach the end (repeated token, `maxPages`) throws `IncompleteWalk`. A partial list is never returned as whole. `requestWholeReply` keeps the first page's envelope (whole-collection counts such as `retiredCount`) and returns a token-less or field-less first reply unchanged.
   4. `requestAgentList(…)`: rows ascend by `(createdAt, id)` and variant params repeat on every page. `isCurrent` is checked before each page; a stale read stops with `CancellationError`.
   5. `requestAllScripts(workspaceId:request:)`: `script.list` uses `cursor`/`nextCursor` (`Cursor.script`). The first request has no `limit` or `cursor`, because hosts without the capability reject them on the full view. A failed page fails the read.
   6. `fillSnapshot(…)` gives each continuation page `pageAttempts` tries with doubling backoff and checks `isCurrent` after every suspension.
   7. `PagedSnapshotFiller` drives one store's snapshot continuation. While `isFilling`, stores keep their previous list instead of a partial one (a partial workspace list would read as deleted workspaces). A failed walk publishes what it has, keeps `isFilling` through the backoff, and resubscribes after a delay that grows with consecutive failures. A newer snapshot, a reset of the reconciler (`epoch`), `cancel()` or a stale owner stops a walk silently. The resubscribe runs outside the walk's task, because resubscribing cancels the filler and a cancelled task would make the requests throw at once.
   8. `NoteContentPages.readWholeNote(…)` follows the `note.get` content cursor on UTF-8 boundaries (§5.2). A note that changes between pages (`rev`) restarts the read, up to `wholeNoteAttempts`. If pages cannot be joined into exactly `contentBytes`, or a later page keeps failing, the first cut reply is returned as a prefix. The first request's errors and cancellations propagate unchanged.

## Consequences

- A store that ignores `CoalescedRead.run`'s result can show stale data until the next trigger.
- Store races (from test comments): a resnapshot parked on its unsubscribe sees that the connection generation advanced and does not open a duplicate subscription over the new connection. A reconnect clears the resnapshot guard. A superseded ack is released on the daemon at once and never registered locally; two racing connects that get one id register it once.
- `NoteStore` workspace switches (ios#996): a switch subscribes the new workspace once, without waiting for a reconnect. A late ack for the old workspace is released. A → B → A ends with one subscription for the last workspace. A store whose connect handler ran before it had a workspace subscribes from `fetchNotes(workspaceId:)`, and a connect delivery queued in the same main-queue window does not reset that subscription. The generation fence alone stops a superseded switch back to the same workspace.

## Code

- `CoalescedRead`: `invalidate()`, `run(…)`, `settleScheduled()`, `cancel()`
- `EventClassification`
- `SubscriptionPush`: `parse(method:params:)`, `nextToken`; `DeltaReconciler`: `fillFromPage(_:)`, `seed(id:value:)`, `patch(id:_:)`, `epoch`
- `CommentStore`: `subscribeLiveState(workspaceId:noteId:generation:)`, `handleSubscriptionPush(_:)`, `fillSnapshot(reconciler:firstToken:)`
- `LiveSubscription`: `acknowledge(_:)`, `requestResnapshot()`, `endResnapshot()`
- `PagedReads`: `requestAllPages(…)`, `requestWholeReply(…)`, `requestAgentList(…)`, `requestAllScripts(workspaceId:request:)`, `fillSnapshot(…)`, `maxPages`, `IncompleteWalk`, `MalformedPage`, `Cursor`; `PagedSnapshotFiller`: `start(…)`, `cancel()`, `resubscribeOutsideWalk(_:)`; `NoteContentPages`: `readWholeNote(…)`
- `LoadPhase`: `beginningKeepingFailure()`, `failingDuringRead(_:)`, `failingVisibly(_:)`, `settled()`
- `ConnectionManager`: `registerSubscriptionHandler(id:handler:)`

# ADR-0610: Paged daemon reads, whole-note reads, and snapshot continuation

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `PagedReads`, `NoteContentPages`, `PagedSnapshotFiller` (`Intent/Services/PagedReads.swift`)

## Context

Paged daemon reads follow the protocol's "bounded reads"
(`server.capabilities.boundedReads: 1`). A bounded daemon answers list reads one
page at a time with `nextToken` (an opaque string, `null` on the last page). It
sends the first page of a collection subscription's snapshot with
`params.nextToken`. It cuts a very large note in `note.get` with
`contentTruncated` / `nextContentOffset`. Older daemons ignore `limit`,
`nextToken`, and `contentOffset` and answer in one reply without a token, so
every walk ends after one request with them.

## Decisions

### 1. Limits

Applies to: `PagedReads` constants

1. `maxPages` (1000) is a hard stop for any walk, so a misbehaving daemon
   cannot loop forever.
2. Page sizes are the daemon maximums: `notePageLimit` 500 (`note.list`,
   `note.subscribe`), `commentPageLimit` 500 threads (`comment.list`,
   `comment.subscribe`), `workspacePageLimit` 200 (`workspace.list` one-shot
   reads), `agentPageLimit` 200 (`agent.list`), `queuePageLimit` 200
   (`agent.getQueue`), `taskPageLimit` 1000 (`task.list` snapshot
   continuations).
3. `pageAttempts` (3) is the number of tries per continuation page before the
   walk gives up. `pageRetryBase` (250 ms) is the first retry delay and doubles
   per attempt. `retryDelay(attempt:)` takes a 1-based attempt.
4. `wholeNoteAttempts` (3) is how many times a whole-note read restarts when
   the note changes mid-walk.
5. `resubscribeDelay(failures:)` is the backoff before resubscribing after a
   continuation walk gave up `failures` times in a row.

### 2. Requests run on the main actor

Applies to: `PagedReads.Request`

Requests run on the main actor, where stores own their connection.

### 3. Cursor names differ per method

Applies to: `PagedReads.Cursor`

A cursor names the request param that carries the token and the reply field
that returns the next one. `Cursor.token` uses `nextToken` in both directions
(most bounded list reads). `Cursor.script` is for `script.list`: `cursor` in,
`nextCursor` out, absent on the last page.

### 4. A partial list is never returned as whole

Applies to: `PagedReads.requestAllPages`, `PagedReads.requestWholeReply`,
`PagedReads.IncompleteWalk`, `PagedReads.MalformedPage`

1. `params` repeat on every page with the previous page's token.
2. `IncompleteWalk` means the walk stopped before the last page: the daemon
   repeated a token or `maxPages` ran out. The rows read so far are not the
   whole list.
3. `requestAllPages` returns the concatenated `field` rows. Any page error is
   thrown, and a walk that cannot reach the last page throws `IncompleteWalk`,
   so callers never publish a partial list as whole.
4. `requestWholeReply` returns one reply: the first page's envelope (with
   whole-collection counts such as `retiredCount` or `queueLength`), with
   `field` holding every page's elements in order and no token. A first reply
   without a token, or without a `field` array, is returned unchanged so
   callers keep their own envelope checks. Page errors propagate. A
   continuation page without a `field` array throws `MalformedPage`.

### 5. Agent lists and scripts

Applies to: `PagedReads.requestAgentList(_:connection:isCurrent:)`,
`PagedReads.requestAllScripts(workspaceId:request:)`

1. `requestAgentList` reads every `agent.list` page of one variant (protocol
   "Paged agent lists and queues"). Rows ascend by `(createdAt, id)`, and the
   variant params (`scope`, `parentAgentId`, `retiredOnly`, …) repeat on every
   page. `isCurrent` is checked before each continuation page. A read that
   turned stale stops with `CancellationError` instead of reading on.
2. `requestAllScripts` returns every `script.list` full-view page as one
   `{ scripts }` reply (protocol "Full-view pages", `boundedReads: 1`). The
   first request has no `limit` or `cursor`, because hosts without the
   capability reject them on the full view. A bounded host then pages by
   default, and `nextCursor` is followed until it is absent. A failed page
   fails the whole read, so callers never treat a partial list as every
   script.

### 6. Snapshot continuation walk

Applies to: `PagedReads.fillSnapshot(from:source:isCurrent:sleep:applyPage:)`,
`PagedReads.FillOutcome`, `PagedReads.PageSource`

1. `fillSnapshot` reads the rest of a paged subscription snapshot (protocol
   §6.9 "Paged snapshots") from `firstToken` and hands each page's rows to
   `applyPage`. `PageSource` is the list read that continues the snapshot.
2. Each page gets `pageAttempts` tries with doubling backoff.
3. `isCurrent` is checked after every suspension, so a superseded walk never
   applies a page.
4. A walk that cannot reach the last page (repeated token, `maxPages`) fails.
5. `FillOutcome.failed`: a page failed `pageAttempts` times, and the caller
   should resubscribe. `FillOutcome.superseded`: a newer snapshot, reset, or
   teardown replaced the target, and the walk stopped silently.

### 7. Whole-note reads follow the content cursor

Applies to: `NoteContentPages`

1. Whole-note reads use the `note.get` content cursor (protocol §5.2 "Bounded
   note and comment reads"). A bounded daemon cuts a note whose row would
   overflow the read budget and marks it `contentTruncated` with
   `contentBytes`, `contentOffset`, and `nextContentOffset`. Passing
   `nextContentOffset` back as `contentOffset` reads on, on UTF-8 boundaries.
2. `readWholeNote` returns the reply in its original shape (`{ note }` or a
   bare note, which `unwrap` accepts) with the whole `content` and no cut
   markers. If the note changes between pages (`rev`), the read restarts. If
   the pages cannot be joined into exactly `contentBytes`, or a later page
   keeps failing, the first (still cut) reply is returned so callers show it as
   a prefix. The first request's errors propagate unchanged (for not-found
   classification), as do cancellations.
3. `readRest` follows `nextContentOffset` and joins the pages onto the first
   read's content. The result is whole only when the join is exactly
   `contentBytes`.
4. `readPage` reads one continuation page with the shared retry policy and
   returns nil when it keeps failing.

### 8. PagedSnapshotFiller keeps the previous list while filling

Applies to: `PagedSnapshotFiller`

1. The filler drives the continuation of one store's paged subscription
   snapshot. It reads the remaining pages into the reconciler, then tells the
   store to publish. A page that keeps failing ends the walk. The store may
   publish what it has, and it resubscribes for a fresh snapshot after a
   backoff that grows with consecutive failed walks (`failures`).
2. While `isFilling`, the reconciler holds only part of the collection, so
   stores keep showing their previous list instead of publishing a partial
   one. A partial workspace list would read as deleted workspaces.
3. `Owner.isCurrent` turns false once the store moved on (another
   subscription, workspace, or note). `Owner.publish(complete:)` gets false
   after a failed walk. `Owner.resubscribe` is called after the failure
   backoff.
4. `sleep` is a test seam for the page retry and resubscribe backoff sleeps.
5. `cancel()` stops any running walk without resubscribing.
6. `start` replaces any running walk. A newer snapshot or reset of the
   reconciler (its `epoch`), `cancel()`, or `owner.isCurrent()` turning false
   stops the walk silently.
7. After a failed walk the reconciler stays partial until the fresh snapshot,
   so `isFilling` holds through the backoff. Deltas must not publish it
   meanwhile.
8. Resubscribing cancels this filler (the store resets its snapshot), so it
   must not run inside the walk's own task. A cancelled task would make the
   unsubscribe and subscribe requests throw `CancellationError` at once. This
   is why `resubscribeOutsideWalk` starts a new task.

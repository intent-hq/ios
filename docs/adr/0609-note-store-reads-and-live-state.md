# ADR-0609: NoteStore reads, slim rows, live state, and task status writes

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `NoteStore` (`Intent/Services/NoteStore.swift`, `Intent/Services/NoteStore+LiveState.swift`, `Intent/Services/NoteStore+TaskStatus.swift`, `Intent/Services/NoteStore+Events.swift`, `Intent/Services/NoteStoreCollections.swift`)
- Related issues: ios#996

## Context

`NoteStore` holds the note list of one workspace. It reads `note.list`, keeps
the list live with `note.subscribe`, falls back to legacy `note:*` events, and
writes task status.

## Decisions

### 1. Load phase and error code

Applies to: `NoteStore.loadPhase`, `NoteStore.invalidParametersErrorCode`

1. `loadPhase` is the `note.list` read for the current workspace. It is reset
   on a workspace change. A failure before any success shows an error with
   Retry, instead of "No notes" or an endless loading placeholder.
2. `invalidParametersErrorCode` is JSON-RPC Invalid params (-32602). The daemon
   also uses it for unknown entity ids.
3. Only the first read shows loading. Refreshes keep the list as it is.
4. A refetch assigns `notes` only when the merged list differs, so an identical
   refetch does not invalidate observers.
5. A cancelled fetch must not publish its late response.

### 2. Workspace switch resets synchronously, then subscribes once

Applies to: `NoteStore.prepareForWorkspaceChange(to:)`,
`NoteStore.resetForFetchIfWorkspaceChanged(to:)`, `NoteStore.fetchNotes(workspaceId:)`

1. Views call `prepareForWorkspaceChange(to:)` from `onChange(of: workspaceId)`
   before they schedule the async fetch. This reset is synchronous so the empty
   state cannot render with the previous workspace's load phase while the fetch
   task has not started.
2. `fetchNotes` clears the previous workspace's notes at once to prevent stale
   data. `resetForFetchIfWorkspaceChanged(to:)` also clears the live
   subscription. It returns the new subscription generation when the workspace
   changed (including the store's first workspace), so the caller subscribes it
   (ios#996): an `onConnected` that ran before any workspace was set subscribed
   nothing. It returns nil when the workspace is unchanged.
3. The subscribe runs after the list, as `onConnected` does. A later switch,
   reconnect, or suspension bumps the generation, so only the last of them
   subscribes.
4. Live-state subscription is owned by `onConnected()` and, when the workspace
   changes, by `fetchNotes(workspaceId:)`. `readNotes` does not subscribe.
5. After a list read, a stale spec note is hydrated with `note.get`, because
   the spec's content links task notes.

### 3. Reconnect is fenced by generation

Applies to: `NoteStore.observeConnection(dropInitialState:)`,
`NoteStore.scheduleReconnect(generation:)`, `NoteStore.onConnected()`

1. The generation is recorded when the connected state is sent (on the main
   actor), not when the queued delivery runs. A workspace change in between
   subscribes by itself (`fetchNotes`), so that connect must not reset and
   subscribe a second time.
2. `scheduleReconnect` fences both queued delivery and execution, because
   cancelling a Combine observer cannot cancel a reconnect task that it has
   already scheduled. `generation` is the one current when the connected state
   was sent.
3. `onConnected` resets live-state tracking and unregisters the old handler,
   because a subscription is invalid after a disconnect.
4. `deinit` removes handlers directly, because it is isolated to the MainActor.

### 4. `note.list` uses the slim projection and reads every page

Applies to: `NoteStore.requestNoteList(workspaceId:)`

`note.list` uses the slim projection (PROTOCOL §5.2 `projection: "slim"`):
bounded rows carry `contentPreview` and `contentLength` instead of full
`content`, so note-heavy workspaces do not pull multi-MB frames. Every page is
read (§5.2 "Bounded note and comment reads": `limit` plus `nextToken`; daemons
without paging answer the whole list). If the daemon rejects the param with
-32602 Invalid params, the store falls back once to the plain full list. This
is defense in depth: pre-8.1 daemons ignore unknown params and serve full rows
instead. Other failures propagate unchanged.

### 5. A slim row never clobbers loaded content

Applies to: `NoteStore.mergeSlimRows(_:)`, `NoteStore.upsertFullNote(_:workspaceId:)`

1. A slim row carries no content. When the cache already holds the full body
   at the same `updatedAt`, the merge keeps that body and its cut markers. A
   re-list must never clobber loaded content.
2. A slim row with a different `updatedAt` wins as-is. Its stale marker makes
   content surfaces refetch through `note.get`, which is safer than keeping a
   possibly outdated body.
3. `upsertFullNote` grafts an already fetched full body onto a cached slim row
   (§5.2). It serves detail views that fetched the note before the slim list
   landed, when `fetchNote`'s own upsert had no row (and no workspace context)
   to replace. It applies only for the same workspace, the same `updatedAt`,
   and a stale row. A newer slim row keeps its stale marker so content surfaces
   refetch instead of rendering an outdated body.

### 6. Single-note fetch tells not-found apart from transient errors

Applies to: `NoteStore.fetchNote(noteId:workspaceId:)`, `NoteStore.NoteFetchResult`,
`NoteStore.isCachedRowNewer(_:thanFetched:)`

1. `NoteFetchResult` separates a definitive not-found (deleted or archived)
   from transient transport errors.
2. The daemon answers `-32602` with `data.code == "not-found"` for a
   nonexistent note (docs/PROTOCOL.md §3.3/§9). Archived notes are treated as
   gone. Any other error is transient, so callers do not mistake network blips
   for deletion.
3. A `-32602` without `data.code == "not-found"` (invalid params or absent
   data, PROTOCOL §3.3/§9) is logged loudly and treated as transient, so a
   client params bug does not silently look like a deletion.
4. A not-found that races the caller's cancellation is treated as transient.
5. A note too large for one read is joined from `contentOffset` pages (§5.2).
   If that fails, the cut note comes back with `contentTruncated`.
6. A cancelled fetch must not publish a late note body.
7. The fetched note replaces a matching cached slim row, but never a newer row
   or a row from another workspace. A cut fetch never replaces a cached whole
   body of the same revision.
8. `isCachedRowNewer` is true when the cached row has a strictly newer
   `updatedAt`. Timestamps are parsed leniently. An unparseable side compares
   as not newer, which keeps the replace behavior.

### 7. Live subscription

Applies to: `NoteStore.subscribeLiveState(workspaceId:generation:)`,
`NoteStore.handleSubscriptionPush(_:)`, `NoteStore.fillSnapshot(reconciler:firstToken:)`,
`NoteStore.resnapshot()`, `NoteStore.handleEvent(_:params:)`

1. The note reconciler is created synchronously before the `note.subscribe`
   await. A push that arrives between the request and its response then finds a
   reconciler ready, so a push is processed only when a reconciler exists.
2. If the server does not support `note.subscribe`, the error response falls
   back to legacy events.
3. The push handler is registered in the same MainActor tick as the
   acknowledgement, which keeps the sync-capture guarantee.
4. `ConnectionManager` routes pushes by subscription id at the transport layer,
   so the handler receives only pushes for this store's subscription id. No
   per-store gate is needed; the router is the single source of truth.
5. `handleEvent` also parses `subscription.push`, for test injection
   compatibility.
6. Legacy refetch events refetch only when the list is not live, to avoid a
   double apply.
7. While a paged snapshot is still filling, deltas do not publish; the list
   publishes once the fill completes.
8. A sequence gap starts a resnapshot. `LiveSubscription.requestResnapshot()`
   guards against a storm.
9. `fillSnapshot` reads the rest of a paged snapshot (§6.9) with `note.list` in
   the subscription's projection (full), then publishes the whole list. The
   previous list stays visible meanwhile. A walk that gives up shows what it
   has, unless that would shrink the list, and then resubscribes.
   `snapshotFiller` is the `PagedSnapshotFiller` that does this.
10. `resnapshot()` unregisters the handler before it sends `note.unsubscribe`.
    After resubscribing, it runs a baseline refetch to bridge the gap.

### 8. Event observation and offscreen suspension

Applies to: `NoteStore.startObservingEvents(workspaceId:)`,
`NoteStore.suspendObservation()`, `NoteStore.resumeObservation(workspaceId:)`

1. `startObservingEvents` removes the old handler first, so handlers do not
   accumulate on reconnect. The server-side event subscription is handled
   centrally by `ConnectionManager.subscribeToAllEvents`.
2. `suspendObservation()` pauses live event, push, and reconnect observation
   while the store is cached offscreen in `WorkspaceDetailStoresCache`. Cached
   notes stay for read-only mode.
3. `resumeObservation(workspaceId:)` restores observation and the live
   subscription when the cached workspace reappears.

### 9. Event classification signatures use optional collections

Applies to: `NoteStore.classify(type:data:)`, `NoteStore.event(from:)`

1. `classify` takes optional event data, because optional payload presence is
   part of the shared classification contract.
2. `event(from:)` returns nil for a non-object event envelope, instead of
   treating it as an empty event.

### 10. Sorted notes match the desktop app

Applies to: `NoteStore.sortedNotes`

The spec note (`isDefault`) comes first. Other notes sort by `createdAt`
ascending (oldest first, newest at the bottom) to match the Electron app.
Archived notes are excluded.

### 11. Task status writes are optimistic and roll back one note

Applies to: `NoteStore.updateTaskLineStatus(noteId:workspaceId:line:status:)`,
`NoteStore.updateTaskNoteStatus(noteId:workspaceId:status:)`, `NoteStore.rollback(_:)`

1. `updateTaskLineStatus` uses the daemon's `task.update` (PROTOCOL §5.4,
   atomic single-line edit). `line` is 1-based. `status` uses the checkbox
   vocabulary (`"todo" | "in-progress" | "done"`). The marker rewrite is
   applied to the local cache first and reverted on error. The confirming
   `note:updated` event reconciles the real state.
2. `updateTaskNoteStatus` uses `task.updateNoteStatus` (PROTOCOL §5.4 task-note
   status vocabulary). It is also optimistic and reverted on error;
   `note:updated` confirms the change.
3. `rollback` restores only that note's pre-request snapshot, by id, so
   concurrent deltas or optimistic writes to other notes that landed mid-flight
   are not clobbered. The note's own `note:updated` event reconciles any
   remaining drift.

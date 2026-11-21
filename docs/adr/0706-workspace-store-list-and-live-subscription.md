# ADR-0706: WorkspaceStore publishes only whole lists and patches the live reconciler

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceStore` (`Intent/Services/WorkspaceStore.swift`),
  event classification (`Intent/Services/WorkspaceStore+EventClassification.swift`),
  local patches (`Intent/Services/WorkspaceStore+LocalPatches.swift`),
  `WorkspaceStore.parseWorkspace` (`Intent/Services/WorkspaceParsing.swift`)
- Related issues: #1066

## Context

`WorkspaceStore` holds the workspace list for one backend. It reads
`workspace.list`, subscribes to `workspace.subscribe` live state, and applies
events. Views treat a workspace that is missing from a loaded list as deleted,
so a partial list is dangerous.

## Decisions

### 1. One store per backend session

Applies to: `WorkspaceStore.init(connectionManager:)`, `WorkspaceStore.removedWorkspaceIds`

Each pinned backend session owns a store over its own connection.
`removedWorkspaceIds` publishes the IDs this backend reported deleted or
archived, from events or from the store's own actions. IDs are unique across
daemons, so consumers need not know which daemon replied.

`workspacesRevision` changes on every `workspaces` mutation, including in-place
array mutations, so derived lists are invalidated.

### 2. Reads coalesce through `CoalescedRead`

Applies to: `WorkspaceStore.fetchReads`, `WorkspaceStore.fetchAll()`, `WorkspaceStore.fetchPass`,
`WorkspaceStore.fetchedRevision`, `WorkspaceStore.loadPhase`

Callers join the running `workspace.list` read. An event while it runs earns a
trailing read, and one during that read a successor. Callers wait for their read
only; a successor it hands off to keeps `isLoading` set without them.

`fetchedRevision` is the read revision the published list is current at. It is
nil while a read runs or after it failed, so `fetchIfNeeded` reads again.

A result invalidated mid-read is dropped for the trailing read. A failure alone
stays dirty without automatic retries. An invalidated read is followed by
another pass, so a failure in it keeps the store loading. A failure ends loading
only with the read, so a caller woken by `isLoading` starts a new read instead
of joining this one.

A failure before any success shows an error with Retry instead of
"No Workspaces". `forgetPublishedWorkspaces()` drops the published list so the
next screen waits for a fresh read; a read still running keeps `isLoading` set.

### 3. A partial list is never published

Applies to: `WorkspaceStore.requestAllWorkspaceRows`, `WorkspaceStore.fillSnapshot`

`requestAllWorkspaceRows` reads every `workspace.list` page (protocol "Paged
workspace lists": `limit` + `nextToken`, rows in `(createdAt, id)` order). A
daemon without paging answers the whole list in one reply, possibly as a bare
array. A failed page fails the whole read, because a missing row would read as a
deleted workspace.

`fillSnapshot` reads the rest of a paged `workspace.subscribe` snapshot
(protocol §6.9) with `workspace.list`, then publishes the whole list. A walk that
gives up keeps the previous list and resubscribes. While a paged snapshot is
still filling, a delta does not publish; the list publishes once complete.

### 4. `lastUpdated` is set before `workspaces`

Applies to: `WorkspaceStore.publishFetchedWorkspaces`

`publishFetchedWorkspaces` keeps a running read's loading state until it
settles. It sets `loadPhase` (and so `lastUpdated`) before `workspaces`, so
observers that gate on "fetched at least once", such as AppCoordinator's
missing-workspace validation, see a non-nil `lastUpdated` on the first
post-fetch change.

### 5. Live subscription lifecycle

Applies to: `WorkspaceStore.onConnected`, `WorkspaceStore.subscribeToEvents`,
`WorkspaceStore.subscribeLiveState`, `WorkspaceStore.handleSubscriptionPush`, `WorkspaceStore.resnapshot`

On a new connection the store resets live-state tracking and unregisters the old
subscription handler, because a subscription is invalid after a disconnect. It
also removes the old event handler, so handlers do not accumulate across
reconnects. The server-side event subscription is handled centrally by
`ConnectionManager.subscribeToAllEvents`.

The reconciler is created synchronously before the `workspace.subscribe`
request, so any push that arrives between the request and its response is safe
to process. When the server does not support `workspace.subscribe`, the error
response falls back to the older event-and-refetch path. The push handler is
registered in the same main-actor tick as the acknowledgement, which preserves
the synchronous-capture guarantee.

`ConnectionManager` routes pushes by `subscriptionId` at the transport layer, so
the handler only receives pushes for its own subscription. The router is the
single source of truth, and no per-store gate is needed.

A sequence gap triggers a resnapshot, guarded against a storm by
`LiveSubscription.requestResnapshot()`. `resnapshot` unregisters the handler
before it unsubscribes, then resubscribes and refetches to bridge the gap.

### 6. Event handling

Applies to: `WorkspaceStore.handleEvent`, `WorkspaceStore.eventDictionary`,
`WorkspaceStore.removedWorkspaceId`, `WorkspaceStore.handledChannels`, `WorkspaceStore.classify`

`handleEvent` also accepts `subscription.push` for live-state updates, for test
injection. `eventDictionary` unwraps the websocket-event-bridge envelope while
it keeps direct event dictionaries that tests and older callers use.

In-place patches apply in every mode, live or not, and before the refetch
decision, because they are the complete application of the event.

`removedWorkspaceId` returns the workspace that an event deletes or archives:
`workspace:deleted`, or a `workspace:updated` whose delta sets `archived: true`.

In `handledChannels`, a trailing colon denotes a channel prefix; other entries
name exact events. `classify` takes optional event data because the shared
classifier signature accepts absent data without inventing a payload.

### 7. Local patches also patch the reconciler

Applies to: `WorkspaceStore+LocalPatches.swift`, `WorkspaceStore.applyConfirmedTitle`,
`WorkspaceStore.workspaceReconciler`

In-place row patches from events and local actions also patch the live
reconciler, so the next delta does not revert them. `workspaceReconciler` is
read-only outside the type so local patches can reseed it.

While a paged snapshot fills, the published list is the previous one. The patch
is then applied to the reconciler's own, fresher row instead of seeding a copy
of the old row. A row on a page not read yet arrives from that page.
`applyConfirmedTitle` follows the same rule.

`updateLastActivity` applies the `lastActivity` that intentd sent (from
`workspace:updated` `changes.lastActivity`) exactly as received.
`updateWaiting` applies a `workspace:waiting-changed` transition (protocol
6.17); the event is self-sufficient, so no refetch is needed.

`clearUnreadAttentionLocally` clears the unread attention flag optimistically,
guarded on "unread" like the server-side `workspace.markSeen` guard, so the dot
disappears immediately. The authoritative state converges through
`workspace:attention-changed` or the live subscription delta.

### 8. The Chief of Staff workspace is never a row

Applies to: `WorkspaceStore.parseWorkspace`

`parseWorkspace` returns nil for rows that miss `id` or `title`, and for the
virtual Chief of Staff workspace (`Workspace.chiefWorkspaceId`). Both
`workspace.list` and the live reconciler's `normalize` therefore drop it.
`addOrUpdate(_:)` also excludes it.

### 9. The daemon owns row fields; the store adds nothing on top

Applies to: `WorkspaceStore.updateLastActivity(workspaceId:lastActivity:)`, `WorkspaceStore.addOrUpdate(_:)`,
`WorkspaceStore.handleEvent`, `Workspace.waiting`

1. intentd derives `lastActivity` (docs/protocol/methods/workspace.md). Agent
   lifecycle events (the eight `AGENT_LIFECYCLE_EVENTS` of the desktop) never
   bump it locally, and unknown agent events change nothing. A
   `workspace:updated` delta applies whatever value intentd sent, and a later
   `workspace.list` or snapshot with an older value is the daemon's truth:
   there is no high-water mark.
2. The `workspace.create` response is the daemon's row, with no local
   timestamp on top. `addOrUpdate` dedupes it against a subscription delta in
   either arrival order (#1066), and the seeded reconciler entry keeps the row
   across a delta that does not mention it.
3. A full row (list or snapshot) without `waiting` means false, also through
   the `Decodable` path (PROTOCOL §5.1 omits the field when false), so the flag
   never sticks from an older row.
4. A snapshot push that arrives before the subscription id returns is still
   applied.
5. A page without rows can still continue (a non-administrator view), a
   repeated token fails the walk, and a delta during the resubscribe backoff
   does not publish a partial snapshot.
6. While live, allowlisted events do not refetch: the live guard sits between
   the in-place patches and the allowlist.

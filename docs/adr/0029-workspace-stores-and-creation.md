# 0029. Workspace stores and creation

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Workspace screens show the list, changes, browser servers, files and creation drafts. Their stores share a connection and react to events while screens come and go.

## Decision

1. **Parsing.** `parseWorkspace(_:)` returns nil for rows without `id`/`title` and for the virtual Chief of Staff workspace (`Workspace.chiefWorkspaceId`), so both `workspace.list` and the live reconciler drop it.
2. **Workspace list (`WorkspaceStore`).**
   1. `loadPhase` covers `workspace.list`; a failure before any success shows an error with Retry, not "No Workspaces". Each pinned backend session owns a store over its own connection.
   2. `fetchReads` is a `CoalescedRead`: callers join the running read; an event while it runs earns a trailing read, and one during that read a successor. `fetchAll()` callers wait only for their read; a successor keeps `isLoading` set. `fetchedRevision` is nil while a read runs or after it failed, so `fetchIfNeeded()` reads again. A failure ends loading only with the read; a failure alone stays dirty without automatic retries.
   3. `requestAllWorkspaceRows()` reads every page (`limit` + `nextToken`, `(createdAt, id)` order); a daemon without paging may answer with a bare array. A failed page fails the read, and a live snapshot fill never publishes a partial list, because views treat a missing workspace as deleted.
   4. `publishFetchedWorkspaces(_:summaryBoundary:)` sets `lastUpdated` before `workspaces`, so observers that gate on "fetched once" (AppCoordinator's missing-workspace check) see it on the first change. `forgetPublishedWorkspaces()` drops the list so the next screen waits for a fresh read.
   5. `removedWorkspaceIds` publishes ids the backend reported deleted or archived (`workspace:deleted`, or `workspace:updated` with `archived: true`); ids are unique across daemons.
   6. In-place patches (`updateLastActivity`, `updateWaiting` for `workspace:waiting-changed` (protocol 6.17), `clearUnreadAttentionLocally`) apply in every mode, before the refetch decision, and also patch the live reconciler so the next delta does not revert them. While a paged snapshot fills, the patch goes to the reconciler's fresher row. `clearUnreadAttentionLocally` mirrors the server's `workspace.markSeen` "unread" guard; `workspace:attention-changed` converges. `lastActivity` is applied exactly as received. `addOrUpdate(_:)` excludes the virtual workspace.
   7. `handledChannels` entries with a trailing colon are prefixes; others are exact events. `eventDictionary(from:)` unwraps the event-bridge envelope and also accepts direct event dictionaries.
3. **Changes (`WorkspaceChangesStore`).**
   1. `loadPhase` covers the snapshot read; a failed refresh keeps the rows and its message, and a shown failure stays through Retry and event refreshes until a read ends. Load More failures are separate (`pageFailure`).
   2. `refresh(workspaceId:)` replaces both lists together and cancels any event refresh's trailing pass. A later refresh, navigation or change event invalidates its result. Event refreshes use `CoalescedRead` and repeat until events settle.
   3. A rebase can move the boundary while a page loads; the bounded walk then restarts.
   4. `startObserving(workspaceId:)` installs the event handler before subscribing and seeds after the acknowledgement. If subscription setup fails, the one-shot snapshot and pull-to-refresh still work. Remote subscriptions do not survive a connection loss.
   5. `stopObserving(preservingSnapshot:)` invalidates pending reads synchronously, so a disappearing screen cannot be repopulated. A commit pushed over Changes keeps its repository and rows for Back.
   6. Rootless events invalidate the whole workspace; inventory events can change the selection. An inventory outage must not erase known roots or block the primary snapshot.
   7. `WorkspaceDiffLoader`: a root commit has no parent, so its files are additions against the empty tree.
4. **Browser servers (`WorkspaceBrowserStore`).** Sources are filtered first, so a dismissed script cannot take an unrelated tab during merging or reappear as a tab when it stops. Events that invalidate a list in flight coalesce into one trailing fetch instead of publishing the stale snapshot.
5. **Creation media (`WorkspaceCreationImages`).**
   1. Photos media belongs to the draft; videos stay on disk until the workspace exists.
   2. Compressed source reads and prepared draft memory are bounded independently of the daemon frame limit; `JSONSerialization` may also escape base64 slashes.
   3. Pasted bytes are snapshotted during the paste action, before the run loop returns, because lazy providers can fail later. Decode and downsample run off the main actor.
   4. The import gate is set synchronously, before any picker or paste task can yield to Create. Each batch is atomic. A cancelled import that finishes after a newer one changes nothing.
   5. `validateRequest(_:)` uses the same serializer and envelope as `ConnectionManager`, bounds the RPC id with `Int.min`, and leaves 1 MiB below the host's 40 MiB.
6. **Creation with videos (`WorkspaceCreationVideoSubmission`).** The first message waits until every video is uploaded. The submission is kept by the draft across dismissal and failure, including the server's workspace and agent identity. The prompt and images are validated before any workspace is created. Ordinary sends are not idempotent: a lost reply is only checked through the composer's recovery owner, never resent (protocol §5.5).
7. **Provider options (`WorkspaceProviderOptions`).** Host policy for creation forms. A refresh hides the previous choices until catalog, settings and authentication were all read. `load()` always revalidates on sheet open or retry, joining concurrent callers; failed or unsupported reads never fall back to the unfiltered auth list. A null enablement map means unset, a missing one is invalid, and numeric flags are rejected. Missing or null authentication is unknown, not signed out.
8. **Workspace transfer.** `WorkspaceTransferExport` keeps its event registration alive before starting; terminal events can precede the start reply, and only the reply's export id selects the result. `WorkspaceTransferRelay` gives one attempt a temporary destination socket and all staging ids. Cancellation never cancels a mutating RPC, because its reply may hold an id needed for cleanup; after commit, cancellation is refused. A returned warning means import succeeded but source finalization failed. Duplicate checks read every destination workspace page and fail closed. `WorkspaceTransferStore` owns the task, so it survives a view task's cancellation during commit.
9. **Daemon-owned rows (from test comments).**
   1. `lastActivity` is derived by intentd (docs/protocol/methods/workspace.md). Agent lifecycle events (the eight `AGENT_LIFECYCLE_EVENTS` of the desktop) never bump it locally, and unknown agent events change nothing. A `workspace:updated` delta applies whatever value intentd sent, and a later `workspace.list` or snapshot with an older value is the daemon's truth: no high-water mark.
   2. The `workspace.create` response is the daemon's row, with no local timestamp on top. `addOrUpdate` dedupes it against a subscription delta in either arrival order (#1066), and the seeded reconciler entry keeps the row across a delta that does not mention it.
   3. A full row (list or snapshot) without `waiting` means false, also through the `Decodable` path (PROTOCOL §5.1 omits the field when false), so the flag never sticks from an older row.
   4. A snapshot push that arrives before the subscription id returns is still applied.
   5. A workspace missing from a loaded list reads as deleted, so a partial list is never published: a page without rows can still continue (non-administrator), a repeated token fails the walk, a delta during the resubscribe backoff does not publish a partial snapshot, and rows from unread pages come from their page, not from the old list.
   6. While live, allowlisted events do not refetch: the live guard sits between the in-place patches and the allowlist.

## Code

- `WorkspaceStore`: `parseWorkspace(_:)`, `loadPhase`, `fetchReads`, `fetchAll()`, `fetchIfNeeded()`, `fetchPass(_:)`, `requestAllWorkspaceRows()`, `publishFetchedWorkspaces(_:summaryBoundary:)`, `forgetPublishedWorkspaces()`, `removedWorkspaceIds`, `removedWorkspaceId(type:workspaceId:data:)`, `updateLastActivity(workspaceId:lastActivity:)`, `updateWaiting(workspaceId:waiting:)`, `clearUnreadAttentionLocally(workspaceId:)`, `addOrUpdate(_:)`, `eventDictionary(from:)`, `handledChannels`
- `WorkspaceTransferExport`, `WorkspaceTransferRelay`: `run(destination:archiveSource:)`, `destinationWorkspaceRows()`; `WorkspaceTransferStore`
- `WorkspaceChangesStore`: `loadPhase`, `pageFailure`, `eventRefreshes`, `refresh(workspaceId:)`, `loadMoreCommits`, `startObserving(workspaceId:)`, `stopObserving(preservingSnapshot:)`, `handleEvent`, `refreshRoots`; `WorkspaceDiffLoader`
- `WorkspaceBrowserStore`: `refresh`, `fetch`
- `WorkspaceCreationImages`: `addPaste`, `addPhotos`, `validateRequest(_:)`; `WorkspaceCreationVideoSubmission`: `submit`, `sendOrCheckAttempt`
- `WorkspaceProviderOptions`: `load()`

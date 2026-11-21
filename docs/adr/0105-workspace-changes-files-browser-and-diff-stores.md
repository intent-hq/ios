# ADR-0105: Workspace changes, files, browser, and diff stores keep shown data through failures

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceChangesStore` (`Intent/Services/WorkspaceChangesStore.swift`),
  `WorkspaceFilesStore` (`Intent/Services/WorkspaceFilesStore.swift`),
  `WorkspaceBrowserStore` (`Intent/Services/WorkspaceBrowserStore.swift`),
  `WorkspaceDiffLoader` (`Intent/Services/WorkspaceDiffLoader.swift`)

## Context

These stores back the workspace Changes, Files, and Browser screens. They read
over RPC, react to events, and must not publish stale or partial results when
the screen changes under them.

## Decisions

### 1. Changes: one snapshot, a separate page failure

Applies to: `WorkspaceChangesStore.loadPhase`, `WorkspaceChangesStore.pageFailure`,
`WorkspaceChangesStore.refresh(workspaceId:)`

`loadPhase` is the snapshot read. A failed refresh keeps the rows and its
message. A shown failure stays through Retry and event refreshes until a read
ends. `pageFailure` is the last Load More failure, independent of the snapshot
read.

`refresh` replaces the staged and unstaged lists together. A later refresh,
navigation, or change event invalidates the result.

### 2. Changes: event refreshes coalesce until events settle

Applies to: `WorkspaceChangesStore.eventRefreshes`, `WorkspaceChangesStore.queueRefresh`,
`WorkspaceChangesStore.selectRoot`

Event-driven refreshes use `CoalescedRead`. An event while one runs earns a
trailing refresh, and one during that refresh another, until events settle.
Selecting a different git root starts a refresh that supersedes any event
refresh, so the store cancels the event refresh's trailing pass.

### 3. Changes: observation and subscription

Applies to: `WorkspaceChangesStore.startObserving(workspaceId:)`, `WorkspaceChangesStore.stopObserving(preservingSnapshot:)`,
`WorkspaceChangesStore.isObserving`, `WorkspaceChangesStore.handleEvent`

`startObserving` installs the event handler before it subscribes, then seeds
after the acknowledgement. The event handler is installed exactly while
observing. Remote subscriptions do not survive a connection loss, so on
reconnect the store clears `subscriptionId` and observes again. When
subscription setup fails, the one-shot snapshot and pull-to-refresh stay usable.

`stopObserving` invalidates pending reads synchronously, so a disappearing
screen cannot be repopulated. With `preservingSnapshot`, a commit pushed over
Changes keeps its repository and rows for Back.

Events without a git root invalidate the workspace. `gitRoot:` inventory events
may change the selection, so they are not filtered by the selected root.

### 4. Changes: bounded commit walk and inventory

Applies to: `WorkspaceChangesStore.loadMoreCommits()`, `WorkspaceChangesStore.refreshRoots`

A rebase may move the boundary while a page is loading. When the page's
`boundarySha` differs, the store restarts the bounded walk with a refresh.

An inventory outage must not erase known roots or prevent the primary snapshot
from loading. It only sets `repositoryErrorMessage`.

### 5. Files: cached listings and synchronous reset

Applies to: `WorkspaceFilesStore.start(workspaceId:)`, `WorkspaceFilesStore.refresh()`,
`WorkspaceFilesStore.reset()`

Entering the same workspace again keeps expansion and cached listings.
`refresh` reloads the root and the visible expanded folders and keeps rows if a
request fails. `reset` invalidates pending replies synchronously, including
replies for a reused workspace ID.

Only loaded, expanded branches are flattened into `rows`; root children have
depth zero.

### 6. Browser: dismissed scripts are filtered before merging

Applies to: `WorkspaceBrowserStore.browsers(workspaceId:)`, `WorkspaceBrowserStore` refresh loop

Dismissed IDs are filtered from the script and tab sources before merging, so a
dismissed script cannot consume an unrelated tab during merging, or reappear as
a tab once the script stops.

Events can invalidate a discovery read already in flight. The store coalesces
all of them into one trailing fetch rather than publishing the stale snapshot.

### 7. Diff: a root commit diffs against the empty tree

Applies to: `WorkspaceDiffLoader`

A root commit has no parent. Its files are additions against the empty tree, so
the old content is empty.

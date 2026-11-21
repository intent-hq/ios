# ADR-0103: Workspace status feeds are shared per backend with bounded journals

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceStatusStore` (`Intent/Services/WorkspaceStatusStore.swift`,
  `Intent/Services/WorkspaceStatusStore+Loading.swift`),
  `WorkspaceStatusPageAdapter` (`Intent/Services/WorkspaceStatusStore+Pages.swift`),
  `WorkspacePrMonitorsStore` (`Intent/Services/WorkspacePrMonitorsStore.swift`),
  `WorkspaceScriptMonitorsStore` (`Intent/Services/WorkspaceScriptMonitorsStore.swift`,
  `Intent/Services/WorkspaceScriptMonitorsStore+Details.swift`,
  `Intent/Services/WorkspaceScriptMonitorsStore+Events.swift`)

## Context

Hooks, PR monitors, and script monitors show live status per workspace.
`WorkspaceStatusStore` owns one remote event feed plus a list read per workspace
bucket, and several views lease the same bucket.

## Decisions

### 1. One store per backend; feeds are workspace scoped or global

Applies to: `WorkspaceStatusStore`, `WorkspacePrMonitorsStore`, `WorkspaceScriptMonitorsStore`

`WorkspaceStatusStore` is the shared status owner for one backend. Hook feeds
are workspace scoped. The PR monitor feed is global, with the same per-workspace
seed lifecycle.

`WorkspacePrMonitorsStore` serves row and conversation leases from one session
PR feed. A row never creates its own registration; each interested workspace has
one acknowledged seed.

`WorkspaceScriptMonitorsStore` holds session-owned active summaries. Only
visible conversations retain a lease.

### 2. Loads are shared and cached per activation

Applies to: `WorkspaceStatusStore.load(workspaceId:refresh:nextPage:)`, `WorkspaceStatusStore.read`

Duplicate callers await the same ACK and read. Empty success and errors are both
cached for this activation; errors retry explicitly or on reconnect.

A read allows at most one follow-up for incomplete events that arrive during it.
Complete events replay over the seed directly, without an extra list request.

A terminal removal event resolves earlier incomplete updates for that row,
including updates queued for reconciliation but not yet read.

### 3. Remote IDs belong to the socket that created them

Applies to: `WorkspaceStatusStore.ConnectionLifetime`, `WorkspaceStatusStore.release(workspaceId:consumer:)`,
`WorkspaceStatusStore.invalidateConnection()`, `WorkspaceStatusStore.invalidate`, feed setup in
`WorkspaceStatusStore+Loading.swift`

Queued cleanup retains `ConnectionLifetime`, even after the store dies, so a
reconnect between scheduling and issuing cleanup invalidates the ID.

`release` removes the consumer synchronously. Pending ACKs stay alive, so their
captured remote IDs can be released without touching a successor feed.

`invalidateConnection()` drops the feeds without unsubscribing them, because the
old socket owns those IDs. Never unsubscribe them on a new socket.

When a bucket is invalidated, the independent feed task must survive
cancellation so it can release late ACKs. List reads have no remote ownership
and are cancelled at once.

Only the request and its connection provenance survive an orphaned ACK. The feed
task never holds the status store alive while it waits for that reply.

### 4. Paged summaries keep only bounded data

Applies to: `WorkspaceStatusStore.pageAdapter`, `WorkspaceStatusPageAdapter`,
`WorkspaceScriptMonitorsStore` event normalization

`pageAdapter` is an optional bounded summary contract. The older hook and PR
paths stay unchanged.

The adapter is opt-in for bounded active summaries. Events are reduced to
summary fields before they enter the journal; full output and configuration are
never retained. Script monitor events contain full snapshots and are reduced to
bounded summary metadata at once.

Recovery replaces page one once. A cursor is never drained or retried
automatically.

`recordRemoval` keeps only bounded tombstone identities (`journalLimit`). With
no list in flight, old tombstones can retire locally. Selected detail reads
have their own generations.

### 5. Script monitor details survive pagination

Applies to: `WorkspaceScriptMonitorsStore.readDetail`, `WorkspaceScriptMonitorsStore.revalidateDetails(workspaceId:)`

A selected detail sheet shares the acknowledged feed. On retry after a reconnect,
the store seeds page one before it revalidates an off-page selection, and it
does not treat absence as terminal.

Only open sheets re-read details. A replacement page may omit an active
selection through pagination, so absence cannot establish its outcome.

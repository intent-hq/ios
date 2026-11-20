# 0015. Workspace auxiliary stores

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Several small stores show workspace side data: assistant threads, background hooks, script monitors, PR monitors. They share patterns for loading and event folds.

## Decision

1. **Assistant.**
   1. `AssistantStore` starts observing events on first use, not at init. Every `BackendSession`, including transient pairing sessions, owns one, and most never open the Assistant tab.
   2. A failed refresh keeps the threads and the failure message. A shown failure stays (banner and spinner together) until the read ends.
   3. The history read walks every page. Threads ascend by creation, so the newest are on the last page.
   4. History is one `loadPhase`. Create and delete failures stay apart in `actionFailure`. `AssistantView` refreshes on reconnect while the store has not loaded or shows an error, so a read that runs after a failure keeps that gate open. A coalesced refresh stays loading from its first pass to its last (added from `AssistantStoreLoadPhaseTests` comments).
2. **Background hooks (§5.40, §6.5).**
   1. `runNow(hookId:)` only acknowledges. The run's outcome arrives as `hook:*` events. `cancel(hookId:)` relies on the `hook:cancelled` event to drop the hook.
   2. `foldHookEvent(…)` is a pure fold, like the FE `foldHookEvent`. Terminal events drop the hook.
   3. An event for an unknown hook sets `needsRefetch`. The fold cannot invent wire fields such as `delayMs` or `createdAt`.
   4. An event with `nextRunAt` keeps the hook scheduled. Without it, a terminal dispatched or evicted event follows and drops it.
   5. A `hook.list` reply that was in flight never brings back a hook that a later event removed, and never refills a list that `unsubscribe()` cleared. A complete cancellation event replays over a stale seed without a recovery read (added from `BackgroundHookStoreTests` comments).
3. **Monitored PRs (§5.42, §6.5; from test comments).**
   1. `foldMonitorEvent(…)` is a pure fold. A re-arm refreshes the baseline on the daemon, so the fold hides pre-re-arm pending state and refetches to converge on the refreshed row.
   2. `check` nil omits the key (presence detection), so the request stays compatible with daemons that predate it.
   3. A monitor that disappeared while disconnected and was replaced by a different one is not resurrected by reissuing an RPC without applying its reply.
   4. A `prMonitor.list` reply that was in flight never brings back a monitor that a complete cancellation event removed, and never refills a list that `unsubscribe()` cleared.
   5. Deinit removes the event handler (monorepo#2211).
4. **PR monitors (§5.42).**
   1. `MonitoredPrStore` gives a conversation a lease on the same monitor cache that workspace rows use.
   2. `flush(monitorId:mode:)` only acknowledges; the outcome arrives as `prMonitor:*` events. `check: true` makes the daemon re-poll the PR first and flush changes against the emit baseline. `daemonDefault` omits the key, so older daemons get the pre-check request. `cancel(monitorId:)` relies on `prMonitor:cancelled` to drop the monitor.
   3. `foldMonitorEvent(…)` is a pure fold. Payloads carry only `{ workspaceId, agentId, monitorId, repo, prNumber, state }` (plus `changes`), so an unknown monitor sets `needsRefetch`.
   4. Cancelled rows are dropped, as `prMonitor.list` excludes them. Registration and idempotent re-arm refresh the baseline server-side, so pending state clears at once and the list is refetched. A merged or closed PR keeps its row as completed, with the final wake delivered.
5. **Terminals.**
   1. `MobileTerminalStore` keys errors by workspace, so a background refresh never shows on another workspace's screen.
   2. Titles: the user's name, else the running program, else the last program, else the terminal's name. User names win. An empty name returns to automatic naming. A rename of an ended terminal or a stale handle to a reused id is ignored.
   3. A returned terminal id means the shell runs on the daemon. It is recorded even if the connection changed meanwhile; dropping it would orphan the PTY.
   4. A terminal whose own event arrived during a list request is newer than that list row.
   5. `MobileTerminalConnection.replay(snapshot:pending:)` merges the buffer and stream, which overlap while a snapshot request is in flight.
6. **Pull requests (FE Home parity).**
   1. `PullRequestListStore` reads `github.authStatus`, then `github.pulls.search` in batches of `batchSize` repositories (FE `repositories()` parity). Each batch keeps its own `nextToken`; "load more" asks only batches with more results. Rows are newest-updated first across batches. Own pull requests are the first segment.
   2. A reply without `pulls` is an error, never an empty result. A newer `load(_:)` supersedes an older one; rows of another query never pass for this query's results, while a failed refresh of the same query keeps its rows under an error. A failed "load more" keeps loaded rows.
   3. `PullRequestDetailStore` loads detail, checks, reviews and files independently; one failure leaves the others visible with their own retry.
7. **Skills.** `SkillCatalogStore` reuses a successful catalog per agent and connection, because skills do not change during a session. Failures are not cached. Offline, the visible catalog is cleared so keyboard acceptance cannot insert a hidden suggestion; the cache repopulates it on reconnect.
8. **Scripts and PR feed.** `WorkspaceScriptDiscovery` is the pure counterpart of the desktop manifest detector; discovery never registers or runs a script, and the desktop's remaining substring categories use command mode (Storybook is a service). `WorkspacePrMonitorsStore` is one session PR feed for row and conversation leases; a row never creates its own registration, and each interested workspace has one acknowledged seed.
9. **Script monitors and scripts.**
   1. `WorkspaceScriptMonitorsStore` holds session-owned active summaries; only visible conversations hold a lease. Events carry full snapshots and are reduced at once to bounded summary metadata.
   2. A selected detail sheet shares the acknowledged feed. Reconnect seeds page one before it revalidates an off-page selection. Only open sheets re-read details. A page can omit an active selection through pagination, so absence never establishes an outcome.
   3. `WorkspaceScriptStore` belongs to one workspace view, so only the launching window presents its browser. Offscreen (`WorkspaceDetailStoresCache`), it pauses subscriptions and reconnect refreshes and keeps known definitions.
   4. Reselecting a script whose start is in flight shares that request. A sent start must settle before a stop or remove can win, so suspension retires view actions but keeps sent starts. An authoritative status bumps the revision, so an older list cannot restore old fields.
   5. `WorkspaceScriptRepository` reads every `script.list` page before it registers, so a match on a later page is not created again.
10. **Status feeds (`WorkspaceStatusStore`).**
   1. One store per backend. Hook feeds are workspace-scoped; the PR monitor feed is global, with the same per-workspace seed lifecycle.
   2. `load(workspaceId:refresh:nextPage:)`: duplicate callers await the same ACK and read. Empty success and errors are cached for the activation; errors retry explicitly or on reconnect. At most one follow-up read covers incomplete events during a read; complete events replay over the seed.
   3. An orphaned ACK keeps only the request and its connection provenance and never holds the store alive. `ConnectionLifetime` stays retained by queued cleanup, so a reconnect between scheduling and cleanup invalidates the id. The old socket owns its ids; they are never unsubscribed on a new socket.
   4. `release` removes a consumer synchronously; pending ACKs stay alive so their remote ids can be released without touching a successor feed. The feed task survives cancellation to release late ACKs; list reads own nothing remote and are cancelled.
   5. A terminal removal resolves earlier incomplete updates for that row, including queued ones.
   6. `WorkspaceStatusPageAdapter` is an opt-in bounded-summary adapter. Events are reduced to summary fields before the journal; full output and configuration are never kept. Recovery replaces page one once and never drains or retries a cursor on its own. Tombstones are bounded; with no list in flight, old ones retire locally.
   7. `WorkspaceStatusWaiters`: one shared operation can outlive any caller. Cancelling a waiter resumes only that caller and never cancels the registration or another consumer.

## Code

- `AssistantStore`: `startObservingIfNeeded()`, `refresh()`, `loadPhase`
- `MonitoredPrStore`: `flush(monitorId:mode:)`, `cancel(monitorId:)`, `foldMonitorEvent(…)`, `FoldResult`
- `MobileTerminalStore`: `errors`, `title(for:)`, `rename(_:to:)`; `MobileTerminalConnection`: `replay(snapshot:pending:)`
- `PullRequestListStore`: `load(_:)`, `loadMore`, `fetch`; `PullRequestDetailStore`: `loadAll`
- `SkillCatalogStore`: `refresh(workspaceId:agentId:connection:)`
- `WorkspaceScriptDiscovery`, `WorkspacePrMonitorsStore`: `retain`, `release`, `seed`
- `WorkspaceScriptMonitorsStore`: `select`, `revalidateDetails`, `fold`; `WorkspaceScriptStore`: `suspendObservation()`, `start`, `stop`, `remove`, `performAction`; `WorkspaceScriptRepository`: `register`
- `WorkspaceStatusStore`: `load(workspaceId:refresh:nextPage:)`, `release`, `ConnectionLifetime`, `invalidateConnection`; `WorkspaceStatusPageAdapter`: `recoverPage`, `recordRemoval`; `WorkspaceStatusWaiters`
- `BackgroundHookStore`: `runNow(hookId:)`, `cancel(hookId:)`, `foldHookEvent(…)`, `FoldResult`
- `MonitoredPrStore`: `foldMonitorEvent(…)`

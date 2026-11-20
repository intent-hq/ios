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
3. **PR monitors (§5.42).**
   1. `MonitoredPrStore` gives a conversation a lease on the same monitor cache that workspace rows use.
   2. `flush(monitorId:mode:)` only acknowledges; the outcome arrives as `prMonitor:*` events. `check: true` makes the daemon re-poll the PR first and flush changes against the emit baseline. `daemonDefault` omits the key, so older daemons get the pre-check request. `cancel(monitorId:)` relies on `prMonitor:cancelled` to drop the monitor.
   3. `foldMonitorEvent(…)` is a pure fold. Payloads carry only `{ workspaceId, agentId, monitorId, repo, prNumber, state }` (plus `changes`), so an unknown monitor sets `needsRefetch`.
   4. Cancelled rows are dropped, as `prMonitor.list` excludes them. Registration and idempotent re-arm refresh the baseline server-side, so pending state clears at once and the list is refetched. A merged or closed PR keeps its row as completed, with the final wake delivered.
4. **Terminals.**
   1. `MobileTerminalStore` keys errors by workspace, so a background refresh never shows on another workspace's screen.
   2. Titles: the user's name, else the running program, else the last program, else the terminal's name. User names win. An empty name returns to automatic naming. A rename of an ended terminal or a stale handle to a reused id is ignored.
   3. A returned terminal id means the shell runs on the daemon. It is recorded even if the connection changed meanwhile; dropping it would orphan the PTY.
   4. A terminal whose own event arrived during a list request is newer than that list row.
   5. `MobileTerminalConnection.replay(snapshot:pending:)` merges the buffer and stream, which overlap while a snapshot request is in flight.
5. **Pull requests (FE Home parity).**
   1. `PullRequestListStore` reads `github.authStatus`, then `github.pulls.search` in batches of `batchSize` repositories (FE `repositories()` parity). Each batch keeps its own `nextToken`; "load more" asks only batches with more results. Rows are newest-updated first across batches. Own pull requests are the first segment.
   2. A reply without `pulls` is an error, never an empty result. A newer `load(_:)` supersedes an older one; rows of another query never pass for this query's results, while a failed refresh of the same query keeps its rows under an error. A failed "load more" keeps loaded rows.
   3. `PullRequestDetailStore` loads detail, checks, reviews and files independently; one failure leaves the others visible with their own retry.
6. **Skills.** `SkillCatalogStore` reuses a successful catalog per agent and connection, because skills do not change during a session. Failures are not cached. Offline, the visible catalog is cleared so keyboard acceptance cannot insert a hidden suggestion; the cache repopulates it on reconnect.
7. **Scripts and PR feed.** `WorkspaceScriptDiscovery` is the pure counterpart of the desktop manifest detector; discovery never registers or runs a script, and the desktop's remaining substring categories use command mode (Storybook is a service). `WorkspacePrMonitorsStore` is one session PR feed for row and conversation leases; a row never creates its own registration, and each interested workspace has one acknowledged seed.

## Code

- `AssistantStore`: `startObservingIfNeeded()`, `refresh()`, `loadPhase`
- `MonitoredPrStore`: `flush(monitorId:mode:)`, `cancel(monitorId:)`, `foldMonitorEvent(…)`, `FoldResult`
- `MobileTerminalStore`: `errors`, `title(for:)`, `rename(_:to:)`; `MobileTerminalConnection`: `replay(snapshot:pending:)`
- `PullRequestListStore`: `load(_:)`, `loadMore`, `fetch`; `PullRequestDetailStore`: `loadAll`
- `SkillCatalogStore`: `refresh(workspaceId:agentId:connection:)`
- `WorkspaceScriptDiscovery`, `WorkspacePrMonitorsStore`: `retain`, `release`, `seed`
- `BackgroundHookStore`: `runNow(hookId:)`, `cancel(hookId:)`, `foldHookEvent(…)`, `FoldResult`
- `MonitoredPrStore`: `foldMonitorEvent(…)`

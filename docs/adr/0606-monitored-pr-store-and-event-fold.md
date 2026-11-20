# ADR-0606: MonitoredPrStore shares the workspace monitor cache and folds prMonitor events

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `MonitoredPrStore`, `PrMonitorFlushMode` (`Intent/Services/MonitoredPrStore.swift`)

## Decisions

### 1. A conversation leases the workspace monitor cache

Applies to: `MonitoredPrStore`

`MonitoredPrStore` is a conversation's lease on the same monitor cache
(`WorkspacePrMonitorsStore`) that workspace rows use.

### 2. `prMonitor.flush` and `prMonitor.cancel` are ack-only

Applies to: `MonitoredPrStore.flush(monitorId:mode:)`, `MonitoredPrStore.cancel(monitorId:)`, `PrMonitorFlushMode`

1. `prMonitor.flush` (PROTOCOL §5.42) delivers a monitor's pending consolidated
   wake now. It is ack only. The outcome arrives as `prMonitor:*` events.
2. `check: true` makes the daemon re-poll the PR first and flush anything that
   changed against the emit baseline. The param is additive and defaults to
   `false`. `PrMonitorFlushMode.daemonDefault` omits the key, so older daemons
   see the pre-check request.
3. `prMonitor.cancel` (§5.42) is also ack only. The `prMonitor:cancelled` event
   drops the monitor.

### 3. An event for an unknown monitor asks for a refetch

Applies to: `MonitoredPrStore.FoldResult.needsRefetch`

The fold cannot invent the missing wire fields (`createdAt`, `lastSnapshot`,
…). `prMonitor:*` payloads carry only
`{ workspaceId, agentId, monitorId, repo, prNumber, state }`, plus `changes` on
`prMonitor:changed`. So when an event names a monitor the list has never seen,
the caller re-runs `prMonitor.list` to converge.

### 4. How each event kind folds

Applies to: `MonitoredPrStore.foldMonitorEvent(monitors:eventType:data:)`

1. `prMonitor:cancelled`: cancelled rows are excluded from `prMonitor.list`, so
   the fold drops the row.
2. `prMonitor:registered`: fires on registration and on an idempotent re-arm. A
   re-arm refreshes the monitor's baseline on the server, so the fold clears
   the pre-re-arm pending state at once and asks for a refetch to converge on
   the refreshed row (fresh `lastSnapshot`, timestamps, …).
3. `prMonitor:emitted`: the consolidated wake was delivered, so pending changes
   are cleared.
4. `prMonitor:completed`: the PR merged or closed. The row is kept, because
   completed monitors stay visible, and the immediate final wake was delivered.

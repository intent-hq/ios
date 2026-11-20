# 0011. Agent list loading, specialists and events

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

`AgentStore` owns the agent list of one workspace, the specialist catalog, and provider and model reads. The list can be large and is read in scopes (groups). The daemon emits many `agent:*` events, some per token.

## Decision

1. **Load phase.** `loadPhase` covers the top-level `agent.list` read for the current workspace. It resets on workspace change. A failure before any success shows an error with Retry, not "No agents" or an endless spinner. Only the first read shows loading; refreshes keep the list.
2. **Workspace switch.**
   1. Views call `prepareForWorkspaceChange(to:)` synchronously from `onChange(of: workspaceId)` before the async fetch. The empty state then cannot render with the old workspace's load phase.
   2. The workspace id advances at once, so an in-flight reply for the old workspace fails the stale-response guard in `_fetchAgents(workspaceId:)`.
3. **Reconnect.** On (re)connect the store refetches. A fetch that failed before the connection came up ("Not connected") must not wait for an unrelated agent event.
4. **Debounce cancellation.** The debounce task is unstructured. Cancelling the caller (for example the deferred swipe-back refresh) is forwarded to it. Each debounce task belongs to exactly one caller, so this never cancels a newer fetch.
5. **Scoped loading.**
   1. `scopedLoading` is opt-in for workspace lists. Name-resolution consumers still need all active rows.
   2. Every read walks all `agent.list` pages of its variant. A failed page fails the read, so a partial list never replaces a whole one.
   3. Per-scope request tickets stop older reads from winning. The epoch also guards an A → B → A workspace navigation.
   4. Groups requested during a refresh own a newer snapshot and are left alone. Older in-flight group reads are superseded by the refresh.
   5. Refresh order is stable and ends with the retired group (`orderedRequestedGroups`), so retire/restore reconciliation prefers the last snapshot.
   6. Parent and orphan snapshots can overlap across retire/restore. Dropping one membership keeps rows still owned by another requested group. A row is deleted once every owning scope drops it.
   7. A scope snapshot can remove its own old rows. It cannot erase a row from a newer overlapping read, including a retirement move.
6. **Specialists (PROTOCOL §5.11).**
   1. A missing `hidden` means not hidden. `pickable` drops hidden specialists, like the FE's `filterPickableSpecialists`.
   2. `modalPickable` also drops `role: "internal"`, like the FE's `filterModalPickableSpecialists`. Internal specialists stay in the full list for by-id lookups and non-picker surfaces.
   3. `orchestrator` is the first `role: "orchestrator"` specialist by id order, like the FE's `selectOrchestratorSpecialist`.
   4. `teamAgents` is advisory and render-only. An unknown or absent `icon` falls back to the default avatar.
   5. `daemonDefaultLabel(for:providerId:)` names the daemon-resolved default only when the preview was resolved for the given provider. Otherwise it shows "Provider default". The daemon omits the resolved fields when resolution gives the provider CLI default.
7. **Providers and mute.**
   1. `fetchProviders()` reads `host.providerAuthStatus` (PROTOCOL §5.14). `authenticated` is tri-state: true, false, or unknown.
   2. `setNotificationsMuted(agentId:workspaceId:muted:)` applies the returned `AgentLite` to the local row at once. The daemon's `agent:updated` push then converges other clients (PROTOCOL §5.5).
8. **Event classification.** Like `WorkspaceStore`, the store uses an explicit allowlist. Every catalog type on its channels is in exactly one table.
   1. Refetch only for events that can change a rendered `AgentSession` field: lifecycle events (status and the streaming, processing and responding flags at turn boundaries), `agent:updated`, `agent:retired`/`agent:restored`, `agent:last-message` and `agent:attention-requested`.
   2. Ignore `agent:stream:*`, including `agent:stream:end`. The persisted row arrives as `agent:last-message` and the flag flip as `agent:idle`/`agent:status-changed`. A row preview refreshes at those events, not per token.
   3. Ignore `agent:message` (a lean echo of `agent:last-message`) and the delivery markers.
   4. Ignore `agent:permission:*`, `agent:process:*`, `agent:queue:*` and subscription bookkeeping. `isWaitingForOtherAgents` updates at the next idle or status boundary.
   5. Ignore delivery bookkeeping between agents, deletion scheduling (membership changes only at `agent:deleted`), and session stats.

## Consequences

- A row's last-message preview can lag mid-turn activity until the turn's persisted row arrives.
- Adding a new `agent:*` event type fails `EventCatalogCoverageTests` until it is classified.

## Code

- `AgentStore`: `loadPhase`, `scopedLoading`, `prepareForWorkspaceChange(to:)`, `fetchAgents(workspaceId:)`, `onConnected()`, `fetchProviders()`, `setNotificationsMuted(agentId:workspaceId:muted:)`, `refetchEventTypes`, `ignoredEventTypes`, `classify(type:data:)`
- `AgentStore` (scoped loading): `_fetchAgents(workspaceId:)`, `loadAgentGroup(_:workspaceId:)`, `orderedRequestedGroups`, `replaceRows(…)`, `retainedByAnotherGroup(_:excluding:)`
- `SpecialistInfo`: `init?(wire:)`, `daemonDefaultLabel(for:providerId:)`; `[SpecialistInfo]`: `pickable`, `modalPickable`, `orchestrator`

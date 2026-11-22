# ADR-0053: Agent list loading, scoped groups and event classification

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AgentStore`, `SpecialistInfo` (`Intent/Services/AgentStore.swift`),
  `AgentStore` scoped loading (`Intent/Services/AgentStore+ScopedLoading.swift`),
  `AgentHistoryStore` (`Intent/Services/AgentHistoryStore.swift`)

## Context

`AgentStore` loads the agent list of one workspace with `agent.list`, keeps it
current from `agent:*` events, and loads optional groups (background, delegated,
orphaned, retired) on demand. It also decodes specialists for pickers.

## Decisions

### 1. Specialist wire fields follow PROTOCOL §5.11

Applies to: `SpecialistInfo`

1. `resolvedModel` is the daemon-resolved default model preview.
   `resolvedProvider` is the provider the preview was resolved for.
2. `hidden` excludes a specialist from picker surfaces.
3. `role` is picker metadata: `"orchestrator"` or `"internal"`.
4. `teamAgents` is the orchestrator's advisory team roster. It is render-only.
5. `icon` is a built-in avatar design name. An unknown or absent value falls
   back to the default.
6. The daemon omits the resolved fields when resolution yields the provider CLI
   default.

### 2. Specialist picker filters match the frontend

Applies to: `Array<SpecialistInfo>.pickable`, `.modalPickable`, `.orchestrator`

1. `pickable` drops `hidden` specialists. It matches the frontend's
   `filterPickableSpecialists`. Lookups by id keep the unfiltered list.
2. `modalPickable` is the set for the New Agent picker: `pickable` minus
   `role: "internal"`. It matches `filterModalPickableSpecialists`. Internal
   specialists stay in the unfiltered list for lookups by id and for other
   surfaces.
3. `orchestrator` is the first `role: "orchestrator"` specialist by id order,
   or nil. It matches `selectOrchestratorSpecialist`.

### 3. The daemon-default model row names the resolved model only for its provider

Applies to: `SpecialistInfo.daemonDefaultLabel(for:providerId:)`

The label is shared by the agent and workspace creation flows. It names the
daemon-resolved default when the preview was computed for the given provider.
Otherwise it says "Provider default".

### 4. A failure before the first success shows an error with Retry

Applies to: `AgentStore.loadPhase`, `AgentStore._fetchAgents(workspaceId:)`

`loadPhase` tracks the top-level `agent.list` read for the current workspace and
is reset on a workspace change. A failure before any success shows an error with
Retry, not "No agents" and not an endless loading placeholder. Only the first
read shows loading. Refreshes keep the list on screen.

### 5. Scoped loading is opt-in

Applies to: `AgentStore.scopedLoading`

Workspace lists opt in. Consumers that resolve names still need all active rows.

### 6. Reconnect refetches the list

Applies to: `AgentStore.onConnected()`

A fetch that failed before the connection was up (for example "Not connected")
is retried as soon as the connection is up. It does not wait for a coincidental
agent event.

### 7. A workspace switch resets state synchronously

Applies to: `AgentStore.prepareForWorkspaceChange(to:)`

Views call this from `onChange(of: workspaceId)` before they schedule the async
fetch. The empty state then cannot render with the previous workspace's load
phase before the fetch task starts. The workspace id advances now, not when the
fetch starts, so an in-flight response for the old workspace already fails the
stale-response guard in `_fetchAgents`.

A switch to the same workspace is a no-op, so a view that reappears does not
flash the loading state. A refetch that returns an identical list does not
assign `agents`; otherwise the list rebuilds under the swipe-back pop
transition.

### 8. Event-driven fetches are debounced; first loads are not

Applies to: `AgentStore.fetchAgents(workspaceId:)`, `AgentStore.createAgent(...)`

Later fetches wait `Constants.AgentStore.fetchDebounce` (300 ms). The first load
for a workspace, or a load with no agents yet, fetches immediately for instant
display. `createAgent` refreshes immediately and bypasses the debounce.

The debounce task is unstructured, so cancellation of the caller (for example
the view's deferred swipe-back refresh on disappear) is forwarded to it
explicitly. Each debounce task belongs to exactly one caller, because a newer
fetch has already cancelled and replaced it. Forwarding never cancels a newer,
unrelated fetch.

### 9. Offscreen workspaces pause observation

Applies to: `AgentStore.suspendObservation()`, `AgentStore.resumeObservation()`

While a workspace's stores sit offscreen in `WorkspaceDetailStoresCache`, live
event and reconnect observation pause and cached rows are kept. Both resume when
the workspace returns on screen.

### 10. Provider and model RPCs

Applies to: `AgentStore.fetchProviders()`, `AgentStore.fetchModels(providerId:)`,
`AgentStore.setNotificationsMuted(agentId:workspaceId:muted:)`

1. `host.providerAuthStatus` (PROTOCOL §5.14) returns `authenticated` as a
   tri-state: true, false, or nil (unknown).
2. `models.list { providerId }` (PROTOCOL §5.30) is the per-provider catalog.
3. The per-agent notification mute is daemon-owned and set with
   `agent.update { changes: { notificationsMuted } }` (PROTOCOL §5.5). The
   result's `AgentLite` echoes the new value and is applied to the local row at
   once. The daemon's `agent:updated` push then converges other clients through
   the ordinary refetch.

### 11. Every list read is whole, and tickets order competing reads

Applies to: `AgentStore._fetchAgents(workspaceId:)`, `AgentStore.fetchAgentGroup(...)`

A refresh reads the visible list and only the groups the user requested. Every
read walks all `agent.list` pages of its variant. A failed page fails the read,
so a partial list never replaces a whole one. Per-scope request tickets stop an
older read from winning a race. The epoch also protects a workspace A → B → A
navigation. A cancelled read publishes nothing, because a disappearing view must
not publish a late response, and a cancelled group stays retryable. A later
read after a cancelled one still publishes.

### 12. Legacy daemons return every active row in the initial read

Applies to: `AgentStore.isAgentGroupLoaded(_:)`, `AgentStore.fetchAgentGroup(...)`

A daemon without scopes already returned all active rows. Retired rows are still
separate and can be fetched on explicit expansion.

### 13. Group refresh order and ownership

Applies to: `AgentStore.loadAgentGroup(_:workspaceId:)`,
`AgentStore.refreshRequestedGroups(...)`, `AgentStore.orderedRequestedGroups`

Expansion is idempotent. Failed and cancelled sections can be retried. Callers
use `list.loadingGroups`, `loadedGroups` and `errors` for section UI. During a
refresh, groups requested during this read own a newer snapshot and are left
alone. Older in-flight group reads are superseded. The refresh order is stable,
and the retired read is the last snapshot, so retire/restore reconciliation
prefers it.

### 14. Overlapping snapshots do not erase newer rows

Applies to: `AgentStore.replaceRows(_:group:sequence:orphanOnly:)`

Parent and orphan snapshots can overlap across retire/restore. Dropping one
membership must keep rows still owned by another requested group. Deletion
converges once every owning scope drops the row. A scope snapshot can remove
its old rows, but cannot erase a row obtained by a newer overlapping read,
including a retirement move.

### 15. Events are classified by explicit tables

Applies to: `AgentStore.handledChannels`, `AgentStore.refetchEventTypes`,
`AgentStore.ignoredEventTypes`

Every catalog type on the `agent:` channel must be in exactly one table.
`IntentTests/EventCatalogCoverageTests.swift` enforces this. The refetch table
is an explicit allowlist, as in `WorkspaceStore`: only events that can change a
field that an `AgentSession` row renders refetch `agent.list`.

1. Lifecycle events cover status and the streaming, processing and responding
   flags at turn boundaries.
2. `agent:updated` carries name, model, effort, the pending-questions markers,
   digest and attention-cleared.
3. `agent:retired` and `agent:restored` change list membership.
4. `agent:last-message` fires once per persisted transcript row and feeds
   `lastAgentResponse`, `lastUserMessage` and `lastMessageRole`.
5. `agent:attention-requested` feeds the pending attention request.

Ignored events have no rendered field, and several fire per token or per tool
call during a turn.

1. `agent:stream:*`, including `agent:stream:end`: the persisted row arrives as
   `agent:last-message`, and the flag flip as `agent:idle` or
   `agent:status-changed`. This is an accepted trade-off. A row's last-message
   preview refreshes at `agent:last-message` or `agent:idle`, not on every
   activity tick, so the list is not refetched per token.
2. `agent:message` is a lean echo; `agent:last-message` carries the content.
   The `agent:message:*` and `agent:user-message:sent` delivery markers carry no
   row field.
3. `agent:permission:*`, `agent:process:*`, `agent:queue:*`,
   `agent:subscriptions-*` and subscription wake bookkeeping:
   `isWaitingForOtherAgents` is picked up at the next idle or status-changed
   boundary.
4. Event-delivery bookkeeping between agents renders nothing.
5. Deletion scheduling: list membership changes only at `agent:deleted`.
6. Session token and cost stats are not part of the list row.

### 16. Agent history is install-wide

Applies to: `AgentHistoryStore`

The history lists agent conversations opened in this install, most recent
first, across every saved connection. One instance serves all windows.

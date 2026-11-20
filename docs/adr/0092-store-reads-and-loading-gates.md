# 0092. Store reads: whole pages, freshness and loading gates

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

Stores read lists from the daemon (`agent.list`, `hook.list`, assistant threads). Reads can be paged, can fail while the socket connects, and can finish after the user moved to another workspace. Views show an empty state only when a store says it has loaded.

## Decision

1. **Paged reads are whole.** `agent.list` on a bounded daemon (protocol "Paged agent lists and queues") returns rows by ascending `(createdAt, id)`, so the newest agents are on the last page. Every caller reads every page of its variant. A walk that fails or does not finish never publishes a part of the list as the whole list. An empty last page ends the walk.
2. **The empty state waits for a successful read.**
   1. `hasLoaded` stays false until the first read for the current workspace succeeds. A "Not connected" error while the socket connects does not show the empty state.
   2. A workspace change resets the gate synchronously, before any read starts (`prepareForWorkspaceChange(to:)`). The same workspace is a no-op, so a re-appear does not flash the loading state.
   3. A sidebar stops waiting for rows once the first read fails, so the open conversation keeps its title.
   4. Assistant history is one `LoadPhase`. Create and delete failures are kept apart in `actionFailure`. The view refreshes on reconnect while it has not loaded or shows an error; a read that runs after a failure keeps that gate open. A coalesced refresh stays loading from its first pass to its last.
3. **Stale results never publish.**
   1. A read for workspace A that finishes after a change to B does not supply rows and does not set `hasLoaded` for B, also in the window before B's read starts.
   2. A read cancelled by its caller (the view disappeared) does not publish, and it does not poison the store; a later read publishes.
   3. A stale `hook.list` reply does not bring back a row that a later event removed, or rows that `unsubscribe` cleared. A complete cancellation event replays over a stale seed without a recovery read. An event without `nextRunAt` clears it; a terminal event follows.
4. **Quiet refreshes.** A refetch that returns an identical list does not assign the observed property. Otherwise the agent list rebuilds under the swipe-back transition. A different list still publishes.
5. **Refetch triggers.** The store refetches on its own when the connection comes up (as `NoteStore` does); it does not wait for an agent event. Only an allowlist of event types triggers a debounced refetch. The streaming firehose does not.

## Consequences

- A store that adds a list read must page it, gate its empty state, and guard against stale results in the same way.

## Code

- `PagedReads`: `requestWholeReply(…)`, `requestAgentList(…)`
- `AgentStore`: `fetchAgents(workspaceId:)`, `prepareForWorkspaceChange(to:)`, `hasLoaded`
- `AssistantStore`: `actionFailure`, `LoadPhase`
- `BackgroundHookStore`: `foldHookEvent`
- `AgentListPagingTests`, `AgentStoreTests`, `AgentStoreScopedLifecycleTests`, `AssistantStoreLoadPhaseTests`, `BackgroundHookStoreTests`

# 0010. Agent detail and summary knowledge

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Many screens show one agent: conversation windows, iPad panes, route validation, late cards. The full row comes from `agent.get`. List reads and events carry only some fields. Replies can arrive late, out of order, or after the caller left.

## Decision

1. **Detail comes only from `agent.get`.** Summary and list rows never seed `AgentDetailStore`. They omit fields such as pending proposal receipts.
2. **One store per backend session.**
   1. One `AgentDetailStore` belongs to one `BackendSession` connection. Loads coalesce and stay reusable after completion, including for route validation and late cards.
   2. Consumers retain an agent for one activation. The last release expires its freshness.
   3. An explicit refresh bypasses a completed cache. It revalidates an older flight through its coalesced trailing read. Proposal mutations use this path.
   4. Public loads (route validation, explicit refresh) do not need a lease. Event reconciliation belongs only to the activation that asked for it.
3. **Ordering.**
   1. `nextStateSequence()` gives one backend-local order for read starts and event receipt. It survives `reset()`, so an old reply can never take a newer boundary.
   2. Each marker keeps the start order of the read that last supplied it (`markerReadSequences`). Patches keep this provenance. A joining caller must not replace it.
   3. A missing or null marker cannot erase a known marker. An explicit empty string can.
   4. `AgentDetail.validate(agentId:workspaceId:)` runs before a detail is published or reused.
4. **Invalidation.** Repeated `invalidate(agentId:)` calls during a read ask for at most one trailing read. More changes during that trailing read leave the entry stale for the next consumer. There is no unbounded reconcile loop.
5. **Cancellation.**
   1. Cancellation can arrive off the main actor while the shared request waits. `LoadInterest` records it synchronously, so a late reply cannot start work for a dead caller.
   2. A queued read is cancellable. A sent read owns a real transport operation. Cancelling the caller retires the read's generation but not the transport callback. The slot stays used until reply, timeout or disconnect.
   3. `retireRead(in:)` detaches the generation in both cases, so an obsolete reply cannot publish.
6. **Request limiter.** `AgentDetailRequestLimiter` is shared by every detail consumer on a backend, including route validation. Cancelling a display interest cancels only its queued `acquire()`. The caller calls `release()` even when cancellation raced the grant.
7. **Summary knowledge.** `AgentSummaryStore` holds display data only. It never starts an RPC, and its values never satisfy an `AgentDetailStore` load.
   1. A successful read owns only the fields it supplied, in RPC start order (`beginRead()`). A late list cannot replace a newer detail or event, but it can fill omitted fields.
   2. Before a read sets an agent's workspace, events can supply provisional fields. Fields from another workspace are dropped when the workspace resolves.
   3. Mutation events publish display changes (for example `specialist`) flat in `data`, not in `AgentLite` metadata.
   4. The top-level and metadata attention fields describe the same values. They are mirrored, so a stale top-level value cannot mask a newer metadata value or clear.
   5. A status-only seed retires older liveness flags (`isStreaming`, `isProcessing`, `isResponding`). Explicit live overlays and newer events keep their own provenance.
8. **Proposal cards.** `ProposalActionStore.loadIfNeeded()` reuses settled detail for card appearance and metadata-generation view tasks.
9. **Watched agents in a conversation.** `ConversationWatchedAgents` seeds summaries with sparse field presence and each participant's canonical workspace. Bundled display rows never grant detail authority.
   1. The view reports real viewport intersection, not `LazyVStack` prefetch. Each window owns its own interest; one window cannot cancel another's.
   2. Selecting an unresolved placeholder is an explicit detail interest. It shares the same backend/agent flight as visible rows and routes.
   3. Enriched activity is display data, never a reason to discover an offscreen agent.

## Consequences

- A screen can show summary data at once, but actions that need full detail wait for `agent.get`.
- The limiter can be full of sent reads that no caller waits for until they time out.

## Code

- `AgentDetailStore`: `load(agentId:workspaceId:refresh:)`, `retain(agentId:)`, `release(agentId:consumer:)`, `invalidate(agentId:)`, `nextStateSequence()`, `retireRead(in:)`, `hasInterest(in:)`, `receivedDetail(_:previous:sequence:)`, `LoadInterest`
- `AgentDetail`: `markerReadSequences`, `validate(agentId:workspaceId:)`
- `AgentDetailRequestLimiter`: `acquire()`, `release()`
- `ConversationWatchedAgents`: `setVisible(_:visible:consumer:)`, `selectedAgent(_:)`, `handleActivity(agentId:lastAgentResponse:digest:)`
- `AgentSummaryStore`: `beginRead()`, `seed(_:workspaceId:since:)`, `seedStatuses(_:since:)`, `handleEvent(_:)`, `displayFields(_:)`

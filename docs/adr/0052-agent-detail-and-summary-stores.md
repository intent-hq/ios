# ADR-0052: Agent detail and summary stores keep separate knowledge and ordered provenance

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AgentDetail`, `AgentDetailStore` (`Intent/Services/AgentDetailStore.swift`),
  `AgentDetailRequestLimiter` (`Intent/Services/AgentDetailRequestLimiter.swift`),
  `AgentSummaryStore` (`Intent/Services/AgentSummaryStore.swift`)

## Context

Agent screens need two kinds of agent data. Full detail comes from `agent.get`.
Display data for rows and cards comes from list reads and `agent:*` events.
Reads, events and local patches can arrive in any order, and a reply can come
back after its caller has gone.

## Decisions

### 1. Only an `agent.get` response creates detail knowledge

Applies to: `AgentDetail`, `AgentDetailStore`

Summary and list rows must not seed `AgentDetailStore`. They omit fields such as
pending proposal receipts.

### 2. `AgentSummaryStore` holds display knowledge only

Applies to: `AgentSummaryStore`

No read in this store starts an RPC. None of its projections may satisfy an
`AgentDetailStore` load.

### 3. One detail store per backend session, with coalesced, reusable loads

Applies to: `AgentDetailStore`, `AgentDetailStore.retain(agentId:)`,
`AgentDetailStore.release(agentId:consumer:)`, `AgentDetailStore.load(agentId:workspaceId:refresh:)`

One instance belongs to one `BackendSession` and connection. Loads coalesce and
stay reusable after they complete, including for route validation and late
cards. Consumers retain an entry for an activation. The last release expires
its freshness. An explicit refresh bypasses a completed cache and revalidates
an older flight through its coalesced trailing read. Proposal mutations use
this path.

### 4. Invalidations during a read earn at most one trailing read

Applies to: `AgentDetailStore.invalidate(agentId:)`, `AgentDetailStore.read(agentId:entry:requestID:epoch:)`

Repeated invalidations during a read request at most one trailing read. More
changes during that trailing read leave the entry stale for the next consumer.
This avoids an unbounded reconciliation loop.

### 5. Cancellation is recorded synchronously, off the main actor

Applies to: `AgentDetailStore.LoadInterest`

Cancellation can arrive off the actor while the shared request is suspended.
`LoadInterest` records it synchronously, so a late reply cannot start work for
a caller that is gone.

### 6. A sent request keeps its transport operation; only a queued one is cancelled

Applies to: `AgentDetailStore.read(agentId:entry:requestID:epoch:)`,
`AgentDetailStore.retireRead(in:)`, `AgentDetailRequestLimiter`

Once `agent.get` is sent, caller cancellation retires the read generation but
does not cancel the transport callback. The limiter slot lasts until the reply,
a timeout or a disconnect, even when no caller remains. A queued read is
cancellable. Retiring either kind detaches its generation, so an obsolete reply
cannot publish.

`AgentDetailRequestLimiter` is shared by every detail consumer on a backend,
including route validation. Cancelling a display interest only cancels its
queued acquisition. The caller of `acquire()` must call `release()` even when
cancellation raced the grant.

### 7. Public loads need no lease; event reconciliation belongs to one activation

Applies to: `AgentDetailStore.hasInterest(in:)`

Public loads (route validation, explicit refresh) do not need a consumer lease.
A reconciliation read started by an event belongs only to the activation that
requested it.

### 8. Identity is validated before a detail is published or reused

Applies to: `AgentDetail.validate(agentId:workspaceId:)`

The supplied agent id and workspace id are checked before a detail is published
or returned from cache.

### 9. One backend-local sequence orders read starts and event receipt

Applies to: `AgentDetailStore.nextStateSequence()`, `AgentDetail.markerReadSequences`

`stateSequence` is one order for actual read starts and notification receipt.
It survives `reset()`, so an old reply can never acquire a newer boundary.
`markerReadSequences` stores the start order of the successful shared RPC that
last supplied each marker. Patches preserve this provenance. Callers that join
a read must not replace it.

### 10. Omission or null cannot erase a known marker; an explicit "" can

Applies to: `AgentDetailStore.receivedDetail(_:previous:sequence:)`

For the marker keys (`pendingQuestionsMessageId`, `dismissedQuestionsMessageId`,
`lastSeenMessageId`), a response that omits the key or sends null keeps the
previous value. An explicit empty string clears it.

### 11. A summary response owns only the fields it supplied, in RPC start order

Applies to: `AgentSummaryStore.beginRead()`, `AgentSummaryStore.seed(_:workspaceId:since:)`

A successful response owns only its supplied fields, ordered by RPC start. A
late list cannot replace a newer detail or event, but it may fill omissions.

### 12. Provisional event data from another workspace is dropped on resolution

Applies to: `AgentSummaryStore.seedRow(_:workspaceId:since:)`

Before a read establishes an agent's workspace, events can supply provisional
display data. When the workspace resolves, fields from another workspace are
discarded.

### 13. Event and row shapes are normalised

Applies to: `AgentSummaryStore.eventFields(type:data:workspace:)`,
`AgentSummaryStore.displayFields(_:)`

1. Mutations publish `specialist` and `attentionRequestCleared` flat, unlike
   `AgentLite` metadata.
2. Top-level and metadata attention fields describe the same values. The store
   writes both, so a stale top-level value cannot mask a newer metadata value
   or a clear.
3. An inactive status retires older liveness flags (`isStreaming`,
   `isProcessing`, `isResponding`) that the row does not supply, because
   status-only subscriptions must retire them. Explicit live overlays and newer
   events keep their own field provenance.

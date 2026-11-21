# ADR-0505: Conversation store: binding, bootstrap, events, and metadata reads

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationStore` (`Intent/Services/ConversationStore.swift`, `Intent/Services/ConversationStore+Lifecycle.swift`, `Intent/Services/ConversationStore+Startup.swift`, `Intent/Services/ConversationStore+Streaming.swift`), `ConversationStorePool` (`Intent/Services/ConversationStorePool.swift`)

## Context

`ConversationStore` owns one agent conversation on one backend. It binds to the
backend-wide agent event feed, opens the live transcript channel (ADR-0503),
loads queue, metadata, and subscriptions, and folds events that arrive before
the workspace is known.

## Decisions

### 1. The pool keeps recent conversations readable

Applies to: `ConversationStorePool`

The pool is the backend-local identity for an active conversation. Models own
leases and presentation state; only the final lease releases the shared live
channel. The most recently opened conversations (`retainedConversationLimit`,
10) stay in memory after their screen closes, so they stay readable during a
connection drop.

`RetainedTranscriptMemoryTests` measures the store-owned data model of those
retained conversations (rows, blocks, search state; the screens are gone). The
ceiling for ten 2,000-message transcripts is 400 MB, and it tightens when the
model slims down.

### 2. Streaming binding is local

Applies to: `ConversationStore.bindStreaming(agentId:workspaceId:)`, `deactivateStreaming()`

Binding is entirely local. `ConnectionManager` owns the backend-wide agent
feed; a view must never wait for or open its own remote feed. Deactivation
keeps visible rows and send recovery state while it releases ownership.

### 3. A second window cannot retarget a live channel

Applies to: `ConversationStore.retainConversation(_:agentId:workspaceId:)`

Agent ids are backend-wide. A second window's route hint cannot replace a live
channel; only shared agent detail supplies workspace authority.

### 4. Bootstrap and reconnect

Applies to: `startBootstrap(reconnecting:)`, `onReconnected()`, `observeConnection()`

- `startBootstrap` is idempotent for one activation and connection, even after
  all its reads settle.
- `onReconnected` is an explicit recovery entry point for connection tests and
  callers. Publisher replay never invokes it; only actual connection
  transitions bootstrap.
- The initial reads may precede the global subscription ACK. When the feed
  becomes ready, the store closes that gap exactly once, including after a
  retry (`needsFeedReconciliation`).

### 5. Live chat entry points

Applies to: `subscribeLiveChat(agentId:workspaceId:)`, `awaitLiveChatSnapshot()`

`subscribeLiveChat` opens the `chat.subscribe` channel that is the transcript's
only source and returns once the registration is acked. Its seq-0 snapshot, or
the snapshot timeout, is awaited through `awaitLiveChatSnapshot`. That wait
parks until the owed snapshot applied (a rejected or silent registration keeps
it owed to the retry), the binding was torn down, or the `snapshotTimeout`
bound elapsed.

### 6. The firehose drives the streaming flag only until the channel is live

Applies to: `handleAgentStreamEvent(_:data:receivedAt:)`

`agent:stream:*` carries no transcript content. The `chat.subscribe` channel is
the transcript's only source and owns the streaming flag once its snapshot
applied (`chatLive`). Until then the firehose is the only liveness signal, so it
raises and lowers the flag alone.

### 7. Turn boundaries re-read state without overriding the channel

Applies to: `refreshStateAfterTurnBoundary()`, `fetchAgentStreamingState(agentId:raiseOnly:liveStateVersion:refresh:)`, `applyFetchedStreamingState(_:raiseOnly:issuedAt:)`

A turn boundary re-reads the agent's state (streaming flag and markers) through
`agent.get`. The channel is authoritative for the flag. The live state version
is captured before the read is scheduled, so a reply that lands after a
snapshot or delta advanced the channel (including the seq-0 snapshot of an
initial load the event raced) leaves the flag alone while still applying the
markers.

`fetchAgentStreamingState`:

- Considers the STAB-125 `turnInFlight` turn-liveness flag alongside
  `isStreaming` and `isResponding`. The headless daemon reports liveness through
  `turnInFlight`; `isStreaming` and `isResponding` may always be false.
- With `raiseOnly`, the flag is only raised, never cleared. This is a backstop
  on view load, so it cannot clobber snapshot or optimistic state.
- A reply or error that lands while the store is bound to a different agent
  than the request's, or unbound by `reset()` since the request was issued, is
  dropped entirely. It must not touch the new conversation's streaming state or
  mark the new agent deleted on a not-found for the previous one. A request
  issued while still unbound (view load, before `subscribeLiveChat` binds the
  same agent) stays valid.

### 8. Each marker has its own revision

Applies to: `applyFetchedMarkers(_:revisions:)`, `MarkerRevisions`

A marker changed by a push or local command during the read is kept. Untouched
markers still seed from the detail, so an unrelated update cannot leave the
entry seen marker or pending question unknown. A pending-question push must not
erase an otherwise authoritative entry seen marker, and the reverse.

### 9. Metadata refreshes belong to the view activation

Applies to: `scheduleMetadataRefresh(raiseOnly:liveStateVersion:)`

Event-triggered reads belong to this view activation, unlike independent route
validation. Cancelling them removes only their shared-detail interest.

### 10. Events before workspace authority are deferred and folded

Applies to: `handleStreamEvent(_:params:ignoringMarkers:receivedAt:)`, `resolveWorkspaceFromDetail()`

While the workspace is unknown, own-agent events are kept until authority
succeeds, including after a failed initial read. The shared detail store
coalesces the metadata refreshes they schedule. When the detail resolves, a
successful shared read supersedes only the fields it supplied, and only events
that preceded its actual RPC start. Local confirmations also win.

### 11. A user-row delta does not end a turn

Applies to: `ConversationStore` `liveTranscript.onAuthoritativeMessages` handler

A user-row delta confirms delivery, not the end of a turn. Only a snapshot or
assistant activity replaces the optimistic Thinking state.

### 12. Test channel helper

Applies to: `setTestChatChannel(subscriptionId:)`

Test-only. It activates the chat channel and sets its subscription id without
the real subscribe flow, so the strict push gate accepts test payloads.

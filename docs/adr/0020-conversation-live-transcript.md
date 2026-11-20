# 0020. Conversation live transcript

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

A conversation's transcript comes from one `chat.subscribe` channel (PROTOCOL §5.5). Its seq-0 snapshot replaces the transcript and its deltas keep it current. Registrations can be rejected, stay silent, or outlive a rebind, reset or reconnect.

## Decision

1. **One source.** `chat.subscribe` is the only transcript source. There is no page fetch to fall back on. `agent:stream:*` carries no content; it is the only liveness signal until the channel is live (`chatLive`), then the channel owns the streaming flag.
2. **Binding and ownership.** `ConversationStore.bindStreaming` is local only. `ConnectionManager` owns the backend-wide agent feed; a view never opens its own remote feed. Deactivation keeps visible rows and send-recovery state while it releases the registration.
3. **Generations.**
   1. `bindingGeneration` advances when the bound agent changes or on `reset()`, never on a same-agent rebind. `whileBound` uses it so work from an old binding cannot publish into a new one. Snapshot waits and recovery timers belong to the binding that armed them.
   2. `registrationGeneration` advances on every registration and channel teardown (reset, reconnect). Replies, pushes, timeouts and retries that outlive their registration are checked after each suspension and dropped.
   3. `recoveryGeneration` makes recovery owned per registration. A superseded recovery cannot touch the newer channel or block its own recovery. `scheduleResnapshot()` takes the token when it schedules.
   4. `liveStateVersion` advances on every applied snapshot or delta. A streaming-state reply captured before it moved is stale.
4. **Registration.**
   1. `openRegistration()` releases the current channel without waiting, drops pending self-heal, and returns the new token. Recovery paths release first, so each registration is released exactly once. A released channel no longer owns liveness; the firehose does until the new snapshot applies.
   2. A snapshot that raced the ack has already seeded the channel.
   3. `retryNow()` skips waits and supersedes the old registration before it releases it.
   4. `releaseActiveRegistration()` releases daemon-side without waiting; nothing observes the reply. A late ack of a registration we left goes through `releaseOrphanedSubscription(_:)`. `release(_:via:)` is static so `deinit` can call it without retaining `self`.
5. **Snapshot wait and self-heal.**
   1. `awaitSnapshot()` parks until the owed seq-0 snapshot applies, the binding is torn down, or `snapshotTimeout` elapses. Rejection, silence and reconnect keep the wait open, because re-registration serves the snapshot within the bound. A registration opened over an empty transcript raises `isLoading`.
   2. An acked registration without a snapshot is presumed stale and replaced on the retry schedule (`armSnapshotTimeout(generation:)`).
   3. Backoff: one delayed re-registration, doubling per consecutive failure up to `maxRetryDelay`, reset when a snapshot applies or on reconnect, like cloudlands-fe `LiveChatClient`. The first retry is attempt 2.
   4. A retry clears `retryTask` before `subscribe` cancels pending recovery, so its own request is not cancelled. A reset, rebind, reconnect or explicit registration during the release owns recovery.
   5. A reconnect registration is the recovery: it drops in-flight replies and the pending retry and restarts backoff. If the bound agent is gone, the load settles at once.
   6. A rejected registration leaves no channel; its snapshot stays owed to the retry.
6. **Gaps.** A gap or a rejected empty snapshot starts `resnapshot(for:)`: a fresh registration whose snapshot replaces the transcript. One rejected empty snapshot gets one replacement. If the replacement is also empty, it is accepted as an authoritative deletion. Only the latest accepted snapshot enables fragment appends (`incrementalDeltas`).
7. **History.** The daemon serves pages oldest-first. Live rows win over page duplicates. The reading position is captured before rows are prepended, with no suspension between. A superseded request cannot hide a newer loader. A full snapshot owns its suffix and keeps only the connected older prefix. A resume snapshot appends since an existing row, so an empty resume keeps the older cursor.
8. **Hydration.** A text read started before a live update cannot erase fragments or a replacement that arrived meanwhile. A later live update or snapshot owns hydrated text; tool and image previews keep their full body. A hydrated body served without its own id keeps the requested block id.
9. **Callbacks.** `onAuthoritativeMessages` gets only incoming server rows, never the merged array with optimistic rows. A delta about another message cannot confirm a local send. `messageIDs` is cached and invalidated at the array owner, so geometry callbacks see deletions before SwiftUI `onChange`; unchanged sets keep their storage so equality checks stay cheap. `messageIDs` reads `messages` first, so cached reads stay observable to SwiftUI.
10. **Agent state reads.** `fetchAgentStreamingState(…)` reads `agent.get` and uses `turnInFlight` (STAB-125) with `isStreaming`/`isResponding`, because the headless daemon reports liveness only through `turnInFlight`.
    1. With `raiseOnly` it only raises the flag; it is a backstop on view load.
    2. A reply for another agent, or after `reset()`, is dropped; it must not mark the new agent deleted. A request issued while unbound stays valid.
    3. Each marker has its own revision. A marker changed during the read is kept; untouched markers still seed from the detail.
    4. The flag is left alone when the channel advanced past the captured `liveStateVersion`. `refreshStateAfterTurnBoundary()` captures the version before it schedules the read.
11. **Startup.** The first reads can precede the global feed ACK. The gap is closed exactly once when the feed becomes ready. Agent ids are backend-wide; a second window's route hint cannot replace a live channel. A shared read supersedes only the fields it supplied and only events before its RPC start; local confirmations also win. `startBootstrap(reconnecting:)` is idempotent per activation and connection. Publisher replay never calls `onReconnected()`. Event-triggered reads belong to the view activation, and the shared detail store keeps the event until authority succeeds.

## Code

- `ConversationLiveTranscript`: `bindingGeneration`, `registrationGeneration`, `recoveryGeneration`, `liveStateVersion`, `snapshotTimeout`, `initialRetryDelay`, `nextRetryDelay`, `emptySnapshotRecoveryAttempts`, `incrementalDeltas`, `chatLive`, `messageIDs`, `onAuthoritativeMessages`, `scheduleResnapshot()`, `whileBound(_:)`
- `ConversationLiveTranscript` (subscribe): `subscribe(agentId:workspaceId:)`, `retryNow()`, `openRegistration()`, `applySubscribeOutcome(_:generation:)`, `resnapshot(for:)`, `awaitSnapshot()`, `armSnapshotTimeout(generation:)`, `releaseActiveRegistration()`, `release(_:via:)`, `releaseOrphanedSubscription(_:)`, `clearChannel()`
- `ConversationLiveTranscript` (history, hydration): `loadOlderMessages(using:beforePrepend:)`, `replaceHistory(with:metadata:)`, `discardHydratedText(_:messageId:)`
- `ConversationStore`: `bindStreaming(agentId:workspaceId:)`, `subscribeLiveChat(agentId:workspaceId:)`, `awaitLiveChatSnapshot()`, `handleAgentStreamEvent(_:data:receivedAt:)`, `refreshStateAfterTurnBoundary()`, `fetchAgentStreamingState(…)`, `startBootstrap(reconnecting:)`, `onReconnected()`

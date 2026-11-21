# ADR-0504: Live transcript state: generations, snapshots, deltas, history, and hydration

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationLiveTranscript` (`Intent/Services/ConversationLiveTranscript.swift`), history extension (`Intent/Services/ConversationLiveTranscript+History.swift`), hydration extension (`Intent/Services/ConversationLiveTranscript+Hydration.swift`)

## Context

`ConversationLiveTranscript` holds the message rows for one bound agent. It
applies `chat.subscribe` snapshots and deltas, pages older history, and
hydrates truncated blocks. ADR-0503 covers the registration lifecycle. This
record covers the state the transcript keeps and how it merges data.

## Decisions

### 1. Three counters scope stale work

Applies to: `bindingGeneration`, `registrationGeneration`, `liveStateVersion`

- `bindingGeneration` advances whenever the bound agent changes (or on
  `reset()`), never on a same-agent rebind. `whileBound` compares against it,
  so work started under an earlier binding cannot publish into a later one.
- `registrationGeneration` advances on every `chat.subscribe` registration and
  channel teardown (`reset`, reconnect), same-agent ones included. A reply,
  push, timeout, or retry that outlived its registration is checked against it
  after each suspension and dropped, so it cannot replace or clear the newer
  channel.
- `liveStateVersion` advances each time the live chat channel applies a
  snapshot or delta. A streaming-state response captured before it moved is
  stale.

### 2. Recovery is owned per registration

Applies to: `recoveryGeneration`, `resnapshotInProgress`, `scheduleResnapshot()`

`recoveryGeneration` is the registration whose gap or rejected-empty-snapshot
recovery is scheduled or in flight. Recovery checks this token before every
mutation and after every suspension. The token stops matching the moment a
newer registration (its own replacement included), `reset`, or reconnect
advances `registrationGeneration`. So a superseded recovery can neither touch
the newer channel nor block its own recovery. `scheduleResnapshot` takes the
token when it schedules, so a registration opened before the work runs
supersedes it.

### 3. Snapshot timeout and backoff

Applies to: `snapshotTimeout`, `initialRetryDelay`, `maxRetryDelay`, `nextRetryDelay`, `snapshotWaiters`, `snapshotPending`

- `snapshotTimeout` (default 5 s) is the ceiling on the seq-0 snapshot after a
  `chat.subscribe` ack. Past it, the registration is presumed stale and
  replaced on the retry schedule.
- Self-heal backoff for a rejected registration or a missing seq-0 snapshot is
  one delayed re-registration, doubling per consecutive failure from
  `initialRetryDelay` (1 s) up to `maxRetryDelay` (30 s). It resets when a
  snapshot applies or the transport reconnects. This mirrors cloudlands-fe's
  `LiveChatClient`.
- `nextRetryDelay` is nil until the first failure after a reset, so the
  backoff starts from `initialRetryDelay`.
- `snapshotWaiters` are `awaitSnapshot` calls parked until the owed seq-0
  snapshot applies, the binding is torn down, or their own `snapshotTimeout`
  deadline.
- `snapshotPending` means a registration's seq-0 snapshot is owed. `subscribe`
  raises it. It is held across rejection, timeout, retry, and reconnect, because
  each re-registers for the same binding. It clears when a snapshot applies or
  the binding is torn down. It is one independent guard, so the
  `state_phase_flag` lint rule is suppressed on its line.

### 4. Channel states and liveness

Applies to: `ChatChannel`, `chatLive`

- `inactive`: no registration, before the first subscribe, or after a
  rejection, reconnect, or reset.
- `registering`: a registration is open (requested or acked) and its seq-0
  snapshot has not applied yet.
- `live`: a snapshot applied; the channel owns the transcript and the streaming
  flag.

While `chatLive` is false (no channel yet, a rejected registration, a
reconnect), the content-free `agent:stream:*` firehose is the only liveness
signal.

### 5. Delta encoding state

Applies to: `incrementalDeltas`, `useFullDeltaEncoding`

Only the latest accepted snapshot can enable fragment appends
(`incrementalDeltas`). A known encoding-parameter rejection is remembered for
this connection in `useFullDeltaEncoding`; reconnect or reset clears it so a
changed daemon can negotiate again.

### 6. Empty snapshots over a populated transcript

Applies to: `shouldAcceptSnapshot(_:resumed:)`, `emptySnapshotRecoveryAttempts`, `maxEmptySnapshotRecoveryAttempts`

One rejected empty snapshot gets a replacement subscription. If the replacement
also reports empty after recovery completes, it is accepted as an
authoritative deletion instead of resubscribing without a bound. A rejected
empty snapshot still resumes snapshot waiters: the registration answered; only
its content is in doubt.

### 7. Snapshot messages are pre-decoded

Applies to: `applySnapshot(_:)`

`parse` pre-decodes snapshot messages off the main actor. The
`ConversationMessage.parseMessages` fallback covers pushes built directly from
raw dictionaries in tests.

### 8. Callbacks to the owner

Applies to: `onSubscribeError`, `onTranscriptReplaced`, `onAuthoritativeMessages`

- `onSubscribeError` fires when `chat.subscribe` is rejected for the
  still-bound agent.
- `onTranscriptReplaced` fires after the live chat channel replaced (snapshot)
  or merged (delta) the transcript, so the owner can reconcile state keyed on
  row residency.
- `onAuthoritativeMessages` passes only incoming server rows, never the merged
  array with optimistic local rows. A delta about another message cannot
  confirm a local send.

### 9. Cached message ids

Applies to: `messageIDs`

Geometry callbacks share one membership snapshot until messages change. The
cache is invalidated at the array owner, so queued callbacks see deletions even
before SwiftUI's `onChange` runs, including same-count replacements. Reading
`messages` keeps cached reads observable to SwiftUI consumers. On content-only
edits the shared `Set` storage is kept, so consumers' equality guards stay
constant-time on later geometry ticks.

### 10. Older history merge

Applies to: `loadOlderMessages(using:beforePrepend:)`, `replaceHistory(with:metadata:)`

- A superseded older-page request cannot dismiss a newer request's loader.
- The daemon serves each page oldest-first. Existing live rows win over page
  duplicates, including any newer content or hydration.
- `beforePrepend` captures the current reading intent before publishing changes
  that can replace the measured row frames. No suspension separates them.
- A full snapshot owns its suffix; only the connected older prefix is kept. A
  resume snapshot is instead an append since an existing row, so even an empty
  resume with `nextToken: null` keeps the older cursor.

### 11. Hydrated text yields to live updates

Applies to: `hydrateBlock(messageId:blockId:)`, `discardHydratedText(_:messageId:)`

A text read begun before a live update cannot erase fragments or an
authoritative replacement that arrived while it waited. Hydration may expand a
partial text body, but a later live update or snapshot owns that text.
Tool and image previews still keep their full hydrated body.

The hydrated-block cache holds `maxHydratedBlocks` (30, like the desktop) and
evicts the oldest. Eviction loses nothing visible, because the full block is
already merged into the row, and an evicted block can be fetched again.
Overlapping requests for one block share one fetch. A fetch that resumes after
`reset()` is not cached. A failed fetch keeps the preview and clears
`hydratingBlockKeys`, so the user can retry.

### 12. Re-delivered, sparse, and omitting payloads

Applies to: `applySnapshot(_:)`, the delta apply path

1. A delta with a seq that was already applied is a re-delivery. It is
   ignored, not treated as a gap. A duplicate or late seq-0 snapshot after
   deltas applied is ignored, so the expected seq and the transcript never
   rewind.
2. A sparse tool progress tick (empty name, same tool call id) keeps the
   earlier block's name, input, and tool kind and takes only the new status. An
   `updated` entity with a name replaces the block, so classification sees the
   fuller raw input; raw input wins over the `_acpTitle` fallback.
3. A first delta without a timestamp gets a local one; the terminal frame's
   server timestamp replaces it.
4. A snapshot is authoritative also for what it omits: missing truncation keys
   reset to defaults, and a snapshot without activity flags clears a stale
   streaming state. A mid-turn snapshot shows the partial in-flight assistant
   row as streaming.
5. A user-row delta with `streamingComplete: true` completes the row, not the
   turn. It neither raises nor clears the streaming flag or the optimistic
   Thinking indicator, and it upserts onto the optimistic local row through the
   synthetic `{messageId}:0` block id.

# ADR-0066: Live transcript subscription: registration, snapshot wait, and recovery

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationLiveTranscript` subscription extension (`Intent/Services/ConversationLiveTranscript+Subscribe.swift`), binding extension (`Intent/Services/ConversationLiveTranscript+Fetch.swift`)

## Context

`chat.subscribe` is the sole transcript source. Its seq-0 snapshot replaces the
transcript and its deltas keep it current. Replies, pushes, timeouts, and
retries can all arrive after the transcript has moved on to a newer
registration, a new agent, a reset, or a reconnect.

## Decisions

### 1. A registration generation token guards every late callback

Applies to: `openRegistration()`, `subscribe(agentId:workspaceId:)`, `applySubscribeOutcome(_:generation:)`

`openRegistration` releases the current channel: its handler no longer reaches
`handlePush`, and its daemon-side subscription is let go without waiting. It
drops pending self-heal and returns the token that the new registration's
reply, handler, timeout, and retry validate against. The recovery paths release
before they reach it, so a registration they replace is released exactly once.
A released channel no longer owns liveness: the firehose does until the new
registration's snapshot applies.

A reply or failure that lands after a rebind, reset, reconnect, or newer
registration leaves the current channel untouched. When such a late reply
carries a subscription id, `releaseOrphanedSubscription` releases it, so the
daemon does not keep pushing for a binding we have left.

### 2. What `subscribe` returns and when it raises loading

Applies to: `subscribe(agentId:workspaceId:)`

`subscribe` returns once the registration is acked or rejected. After an ack,
the snapshot is awaited through `awaitSnapshot`, bounded by `snapshotTimeout`.
After a rejection, a backoff retry is scheduled. A registration opened over an
empty transcript raises `isLoading` until its snapshot lands. On ack, a
snapshot that raced the ack has already seeded the channel, so no timeout is
armed.

### 3. Incremental delta encoding falls back once

Applies to: `requestSubscription(agentId:generation:)`, `rejectsDeltaEncoding(_:)`, `useFullDeltaEncoding`

Only the known rejection of the optional `deltaEncoding` field is retried, and
only once. Normal recovery keeps omitting the field until a reconnect
negotiates again (`prepareForReconnect` resets `useFullDeltaEncoding`). The
match is bound to this exact parameter: its name in an expected-field list or
in another clause is not a compatibility signal.

### 4. A missing agent settles the load at once

Applies to: `applySubscribeOutcome(_:generation:)`

When `chat.subscribe` fails with entity-not-found, the bound agent is gone and
no snapshot will come. The load settles now instead of at the wait's deadline.
A rejected registration otherwise leaves no channel (`clearChannel`); its
snapshot stays owed to the retry, so waiters are not released.

### 5. Snapshot waits are bounded and survive re-registration

Applies to: `awaitSnapshot()`, `armSnapshotTimeout(generation:)`

`awaitSnapshot` parks until the owed seq-0 snapshot applies, the binding is
torn down (rebind, reset), or `snapshotTimeout` elapses. A rejected or silent
registration and a reconnect keep the wait open, because their re-registration
serves the snapshot within the bound. It returns at once when no snapshot is
owed. When a registration acks but its seq-0 snapshot never comes, the
presumed-stale registration is replaced on the retry schedule; waiters keep
parking for the replacement, bounded by their own deadline.

### 6. Gap recovery is a fresh registration

Applies to: `resnapshot(for:)`, `retryNow()`

Gap and rejected-empty-snapshot recovery opens a fresh registration whose
seq-0 snapshot replaces the transcript. There is no page fetch to fall back on;
a registration that fails or stays silent self-heals on the retry schedule
inside `subscribe`. A recovery whose registration was superseded before it ran,
or while it released the old subscription, does nothing. The newer
registration (or `reset` or reconnect) owns recovery now, and its own gaps
schedule their own recovery because `recoveryGeneration` no longer matches.

The running recovery owns the channel, so it cancels any timeout or retry armed
for the registration it replaces. Opening the replacement advances the
generation, which ends this recovery's ownership.

`retryNow` bypasses snapshot and backoff waits. It supersedes the old
registration before releasing it, so late replies and already-running recovery
cannot win.

### 7. Retry backoff

Applies to: `scheduleRetry(generation:)`, `resetBackoff()`

The attempt count includes the initial registration, so the first retry is
attempt 2. The retry stays cancellable through `retryTask` across the release
of the old subscription. A reset, rebind, reconnect, or explicit registration
in the meantime owns recovery, and the retry must not revive its binding.
`retryTask` is cleared before `subscribe` cancels pending recovery, so the
retry's own `chat.subscribe` request is not cancelled midway.

### 8. Reconnect is the recovery

Applies to: `prepareForReconnect()`

The reconnect registration is the recovery. The outage's in-flight replies and
pending retry are dropped, and the backoff starts over. Snapshot waiters keep
parking for that registration's snapshot.

### 9. Releasing registrations

Applies to: `releaseCurrentSubscription()`, `releaseActiveRegistration()`, `release(_:via:)`

- `releaseCurrentSubscription` unregisters and releases (logging any failure)
  the current registration, whose seq-0 never arrived or whose sequence broke,
  ahead of a fresh one.
- `releaseActiveRegistration` runs on unbind (rebind, `reset`). It detaches the
  acked registration and releases it daemon-side without waiting. Nothing
  observes the reply, so a release that resolves or fails late cannot touch a
  later binding. A pending or rejected registration has nothing to release; its
  late ack goes through `releaseOrphanedSubscription`.
- `release(_:via:)` is a fire-and-forget `chat.unsubscribe`. It is static so
  `deinit` can release the active registration without retaining `self`.

### 10. Binding scopes every load

Applies to: `bind(agentId:workspaceId:)`, `whileBound(_:)`, `decodeMessageBlock(_:blockId:)`

Snapshot waits and recovery timers belong to the binding they were armed
under; a new agent cancels them and starts its own. `whileBound` returns the
result of `work` only while the transcript stays on its original agent.
`decodeMessageBlock` takes the requested block id, so a hydrated body served
without its own `id` keeps the identity of the row it replaces.

# ADR-0221: Subscription push routing and buffering

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

Live stores (chat, comments, notes, collections) subscribe to daemon channels. The daemon answers the subscribe request with an id and then sends `subscription.push` frames (PROTOCOL §6.1). The seq-0 snapshot can arrive before the store has the id and registers its handler. Subscription ids are per connection and restart after a daemon restart.

## Decision

1. **One router.** `ConnectionSubscriptionRouter` is the only dispatcher of `subscription.push`. A push goes to the handler registered for its `subscriptionId`, never to the general `eventHandlers`. A push without its required fields (`seq`, `kind`) is dropped: no router dispatch and no broadcast. Re-registering an id replaces the old handler.
2. **Early pushes are buffered.**
   1. A push for an id with no handler is buffered, not broadcast. Registration replays the buffered pushes for that id synchronously, in arrival order, then clears them. Later pushes route live.
   2. The buffer is shared and bounded: `defaultBufferLimit` (64) frames, oldest evicted first, and entries older than `defaultBufferTTL` (30 s) are pruned.
   3. A replayed collection snapshot (array-shaped) is delivered intact. The next live delta continues the sequence without a gap, so the store does not resnapshot.
3. **Unregistered ids.**
   1. `unregister(id:)` drops the id's buffered pushes and keeps a short-lived tombstone. Straggler pushes for that id (the daemon's unsubscribe still in flight) are dropped, not buffered: they can never replay and only add eviction pressure.
   2. A seq-0 snapshot for a tombstoned id means the daemon reused the id for a new subscription, so it clears the tombstone and is buffered. A new id is not affected by any tombstone.
4. **Per connection.** On disconnect, `reset()` drops every handler, buffered push and tombstone. Old state must not leak into the next connection, where the daemon can reuse ids (monorepo#2213).

## Consequences

- A store must register its handler as soon as its subscribe reply resumes; a push older than the TTL is lost and the store must resnapshot.

## Code

- `ConnectionSubscriptionRouter`: `register(id:handler:)`, `unregister(id:)`, `route(_:)`, `reset()`, `defaultBufferLimit`, `defaultBufferTTL`
- `ConnectionManager`: `registerSubscriptionHandler(id:handler:)`, `unregisterSubscriptionHandler(id:)`, `hasBufferedSubscriptionPush(for:)`
- `ConnectionManagerSubscriptionTests`, `ConnectionManagerHostRaceTests`

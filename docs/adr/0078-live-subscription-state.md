# ADR-0078: LiveSubscription is one enum for a store's live subscription state

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `LiveSubscription` (`Intent/Services/LiveSubscription.swift`); used by `WorkspaceStore`, `NoteStore`, `TaskStore`, `CommentStore`

## Context

Stores subscribe to a live list with `*.subscribe`. Before a snapshot arrives,
legacy events refetch the list. After a snapshot, `subscription.push` drives
the list. A sequence gap starts a repair (a "resnapshot").

## Decisions

### 1. One enum replaces three side-by-side fields

Applies to: `LiveSubscription`

Each store used to keep three fields: the acknowledged subscription id, a
"live" Bool (a snapshot was applied, so legacy events no longer refetch), and a
resnapshot guard (a gap repair is running, so further gaps are ignored). Every
combination of the three is reachable, so each case is one combination. Stores
change the state only through the named transitions, never field by field.

### 2. The id is the subscription whose push handler is registered

Applies to: `LiveSubscription.id`

During a resnapshot the id is the old id while `*.unsubscribe` is in flight,
nil while resubscribing, and the new id once that is acknowledged.

### 3. Case meanings

Applies to: `LiveSubscription.Feed`, the cases of `LiveSubscription`

1. `Feed.legacy`: no snapshot applied yet, so legacy events refetch the list.
   `Feed.live`: a snapshot was applied, so pushes drive the list.
2. `idle`: nothing acknowledged and no snapshot; the store runs on legacy
   events.
3. `live(id:)`: a snapshot was applied. `id` is nil only when a push was
   applied before any acknowledgement. Tests inject pushes through
   `handleEvent`.
4. `resnapshotting(id:feed:)`: a gap repair (unsubscribe, resubscribe,
   baseline refetch) is running.
5. `subscribed(id:)`: `*.subscribe` was acknowledged and its handler
   registered; no snapshot yet.
6. `isLive` is true once a snapshot made the list live, and legacy refetches
   are then skipped. `isResnapshotting` is true while a gap repair runs, and
   further gaps must not start another.

### 4. Transition contracts

1. `acknowledge(_:)`: `*.subscribe` acknowledged a new id. It keeps the feed
   and any running resnapshot. It returns the previous id, and the caller must
   unregister that handler, even when it equals the new id.
2. `clearId()`: drops the id and keeps the feed. Used for `TaskStore`'s failed
   subscribe and for the step after a resnapshot's unsubscribe.
3. `subscribeFailed()`: `*.subscribe` failed or acked without an id. It drops
   the id and falls back to legacy events.
4. `requestResnapshot()`: a sequence gap was detected. It starts a resnapshot
   and returns true, or returns false when one is already running. The feed is
   unchanged until the resnapshot body starts.
5. `beginResnapshot()`: the resnapshot body starts, and the list is no longer
   live.
6. `endResnapshot()`: the resnapshot body finished. It is a no-op when a
   teardown already ended it.
7. `reset()`: teardown (reconnect, workspace or note switch). It returns the
   id whose handler the caller unregisters, if it does.

### 5. Races between resnapshots, reconnects, and acks

Applies to: `LiveSubscription`, `WorkspaceStore`, `NoteStore`, `TaskStore`, `CommentStore`

1. A resnapshot parked on its `*.unsubscribe` sees that the connection
   generation advanced and does not open a duplicate subscription over the new
   connection.
2. A reconnect clears the resnapshot guard.
3. A superseded ack is released on the daemon at once and never registered
   locally. Two racing connects that get one id register it once.
4. A store refetches on legacy events only while not live, to avoid applying a
   change twice. During a resnapshot, a baseline refetch bridges the gap.

# 0100. Live subscription snapshots and deltas

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

Stores keep live lists in step with the daemon through `subscription.push`. A push is a seq-0 snapshot or a numbered delta. Large snapshots arrive in pages, and deltas can arrive while the pages are still loading. The transcript must stay smooth, so it must not decode JSON on the main actor.

## Decision

1. **Paged snapshots (PROTOCOL §6.9).** The snapshot push carries `nextToken`. Later pages merge under the deltas that arrived in the meantime: a delta always wins over a page row.
2. **Duplicate rows.** A paged read (for example `comment.list` rounds) can serve the same row twice. The later row is newer and wins.
3. **New snapshot.** A new snapshot forgets earlier removals. Its own pages may add a row that an old delta removed.
4. **Sequence.** A delta applies only after a snapshot seeded the reconciler, and only with the next seq. A gap or an unseeded delta fails, so the store resubscribes.
5. **Chat snapshot shape (PROTOCOL §7.1).** The chat channel's seq-0 snapshot is an object with `messages` plus metadata and activity flags. `messages` moves into the snapshot rows and is not copied into `snapshotMeta`. A snapshot object without a `messages` array, or a scalar snapshot, is malformed.
6. **Decode off the main actor.** Chat snapshot rows and block-shaped delta entities (added, then updated) are decoded at parse time, off the main actor in the live pump. The transcript only merges typed values.
7. **Raw rows.** Collection entities are not block-shaped. Their raw dictionaries pass through untouched, so a reducer can consume them.

## Consequences

- A store that skips the seq check can show a list that silently drifts from the daemon.
- Adding a new chat-shaped channel means extending the parse-time decode, not decoding in the view.

## Code

- `SubscriptionPush`: `snapshotMeta`, `snapshotMessages`, `DeltaPayload`, `chatBlocks`
- `DeltaReconciler`: `applySnapshot(seq:rawItems:)`, `applyDelta(seq:delta:)`, `fillFromPage(_:)`
- `ConversationLiveTranscript`

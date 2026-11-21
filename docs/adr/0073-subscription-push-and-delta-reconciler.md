# ADR-0073: Subscription push parsing and the delta reconciler

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `SubscriptionPush`, `SubscriptionPush.ChatBlockEntity`, `SubscriptionPush.DeltaPayload`, `DeltaReconciler` (`Intent/Services/DeltaSubscription.swift`)
- Related issues: ios#258

## Context

The daemon sends `subscription.push` notifications for collection channels and
for the chat channel. Each push is a snapshot or a delta with a sequence
number. `SubscriptionPush` parses the envelope, and `DeltaReconciler` folds
pushes into an id-keyed collection with stable ordering.

## Decisions

### 1. Parsing and chat decoding run off the main actor

Applies to: `SubscriptionPush`, `SubscriptionPush.parse(method:params:)`

`SubscriptionPush` is nonisolated so `parse` can run in the off-main inbound
frame parse (`ConnectionManager.parseInboundFrame`). Chat-channel payloads are
pre-decoded there into typed values (`snapshotMessages`,
`DeltaPayload.chatBlocks`), so the caller's isolation domain (off-main in the
live frame pump) pays the decode cost and the main actor only merges them. A
new chat-shaped channel extends this parse-time decode; views never decode.

It is `@unchecked Sendable` because its dictionaries are parsed JSON that is
never mutated after parsing.

### 2. Optional collections carry meaning

Applies to: `SubscriptionPush.snapshot`, `snapshotMeta`, `snapshotMessages`, `DeltaPayload.chatBlocks`, `DeltaPayload.decodeChatBlocks(added:updated:)`, `SubscriptionPush.init(subscriptionId:kind:seq:snapshot:delta:snapshotMeta:snapshotMessages:nextToken:)`

Nil and empty are different, which is why `discouraged_optional_collection`
is suppressed on these members.

- `snapshot`: nil means no snapshot payload (a delta push). An empty snapshot
  authoritatively clears the collection.
- `snapshotMeta`: snapshot-level metadata for object-shaped snapshots (chat
  channel): `agentId`, `truncated`, `totalMessages`, `nextToken`, plus activity
  flags such as `isResponding`, `isWaitingOnTool`, `turnInFlight`, and
  `lastStreamActivityAt`. It is nil for array-shaped snapshots (collection
  channels). Nil identifies a collection snapshot; even empty metadata
  identifies a conversation snapshot. Its `messages` moves into
  `snapshotMessages` and is not copied into `snapshotMeta`. A chat snapshot
  object without a `messages` array, or a scalar snapshot, is malformed.
- `snapshotMessages`: chat-channel snapshot `messages` pre-decoded by `parse`,
  with undecodable rows dropped, matching `ConversationMessage.parseMessage`.
  Nil for collection channels and for pushes built without `parse`; nil asks
  the consumer for fallback decoding, and an empty array is an already-decoded
  empty result.
- `chatBlocks`: `added` then `updated` pre-decoded as chat block entities by
  `parse`; entities that are not block-shaped or do not decode are dropped. Nil
  when no entity is block-shaped (collection channels) and for payloads built
  without `parse`; nil asks for fallback decoding. `decodeChatBlocks` returns
  nil when no entity is block-shaped, so a collection delta stays distinct from
  a chat delta whose block-shaped rows all failed to decode (an empty array).
  Collection entities are not block-shaped: their raw dictionaries pass through
  untouched so the store's reducer can consume them.

### 3. Paged collection snapshots

Applies to: `SubscriptionPush.nextToken`, `DeltaReconciler.fillFromPage(_:)`

Protocol §6.9 "Paged snapshots": `nextToken` is the list-read token for the rows
after this first page. It is nil when the snapshot holds the whole collection,
and for every non-snapshot push.

### 4. Chat block entities

Applies to: `ChatBlockEntity`, `ShapedChatBlockEntity`, `ChatBlockEntity.decodeAll(_:)`

- A `ChatBlockEntity` is one chat-channel block delta entity (PROTOCOL §7.1)
  with its `block` decoded into a `ContentBlock`.
- `textDelta` is an append-only text or thinking fragment, kept outside the full
  block model. The reducer uses it only after a snapshot echoes incremental
  delta encoding.
- A missing role means assistant.
- `metadata` is the persisted row's metadata. Only re-read and terminal
  entities carry it (PROTOCOL 07 §7.1); it is empty when the entity has none.
- `ShapedChatBlockEntity` is a block-shaped entity (`messageId` plus `block`)
  before its block is decoded. It is the shape check shared by the per-entity
  and batched paths.
- Full text is authoritative. A malformed mixed payload is rejected, and a
  fragment-only block needs a stable wire id to append safely.
- `decodeAll` decodes every entity's block in one `ContentBlock.decodeBatch`
  pass (ios#258). It returns the same elements, in order, as mapping
  `init?(entity:)`.

### 5. Reconciler sequencing

Applies to: `DeltaReconciler.applyDelta(seq:delta:)`, `reset()`, `epoch`

`applyDelta` applies only a contiguous delta: the reconciler must have been
seeded by a snapshot, and the delta must carry the next seq. False means a gap
or an unseeded delta, and the caller should resnapshot. A store that skips this
check shows a list that silently drifts from the daemon. `reset` forgets all state so the next snapshot rebuilds from
scratch. `epoch` is bumped by every snapshot and reset, so a stale page walk can
tell it was superseded. `values()` keeps the server snapshot and insertion
order.

### 6. Local rows and later pages

Applies to: `DeltaReconciler.seed(id:value:)`, `patch(id:_:)`, `fillFromPage(_:)`, `changedSinceSnapshot`, `removedSinceSnapshot`

- `seed` inserts or updates an already-normalized value without touching
  sequence tracking, for example an optimistic row from an RPC response. New
  ids go to the front; existing ids keep their position.
- `patch` applies a local change to the current row, if present, and keeps later
  snapshot pages from overriding it. Unlike `seed`, it never inserts a row:
  while a paged snapshot fills, a row not read yet comes from its page.
- `changedSinceSnapshot` holds ids a delta or local seed added or updated since
  the last snapshot; they are newer than any later page row.
  `removedSinceSnapshot` holds ids a delta removed; a later page must not re-add
  them. A new snapshot clears both sets, so it forgets earlier removals: its
  own pages may add a row that an old delta removed.
- `fillFromPage` adds the rows of a later page (protocol §6.9). It skips rows in
  either set and upserts the rest. A list walk that serves the same row twice
  (`comment.list` rounds) keeps the later, newer one.

# ADR-0502: Conversation commands: queue reconciliation and agent markers

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationCommands` (`Intent/Services/ConversationCommands.swift`), `ConversationCommands.QueueMutation`, `QueueMutationHistory`, `QueueRead` (`Intent/Services/ConversationCommands+QueueEvents.swift`)

## Context

`ConversationCommands` sends agent RPCs for one conversation and keeps the
message queue and the question and seen markers. The queue can change from
three sources at once: `agent:queue:updated` events, paged `agent.getQueue`
reads, and acknowledged local mutations. They arrive in any order.

## Decisions

### 1. The question marker has three states and is never coerced

Applies to: `ConversationCommands.AgentState.pendingQuestionsMessageId`

PROTOCOL §5.5: `nil` when the field is absent from the response (legacy
daemon), `""` when written empty (nothing pending), else the question-bearing
message id.

### 2. `userAppMessageId` only correlates

Applies to: `ConversationCommands.sendMessage(_:)`

`userAppMessageId` correlates auto-queue and drain. It is not a replay or
dedup guarantee (PROTOCOL §5.5).

### 3. A send seeds the queue only when nothing newer landed

Applies to: `ConversationCommands.sendMessage(_:)`

A queued send seeds the queue only if no newer queue event or read landed
during the request (`issuedQueueRevision == queueRevision`). The store also
skips seeding when a transcript echo already won.

### 4. One message seek

Applies to: `ConversationCommands.fetchMessage(agentId:messageId:workspaceId:)`

It returns nil when the message is absent. The caller classifies unknown-id
errors. `invalidParametersErrorCode` (-32602) is JSON-RPC Invalid params, which
the daemon also uses for unknown entity ids.

### 5. Queue reads replace the whole queue and stop when overtaken

Applies to: `ConversationCommands.fetchQueue(agentId:)`, `QueueReadSuperseded`

- Every `agent.getQueue` page replaces the queue, because positions are
  whole-queue.
- A malformed envelope preserves existing rows; a valid empty array clears
  them.
- Later acknowledged changes and processing removals fold in without
  discarding unrelated seed rows.
- The page token is a queue position. A walk overtaken by a queue event,
  processing removal, local mutation, reset, or newer read (up to its last
  reply) stops without publishing (`QueueReadSuperseded`). The daemon's
  following `agent:queue:updated` carries the whole queue, and any re-read
  starts from the first page.
- Drains and local edits shift positions too, even when they fold into the
  read, so a paged walk stops when `read.mutations` is not empty.
- A change while the last page was in flight can have shifted it too. A single
  page is one snapshot, so its folded-in changes still apply.

### 6. Mutations apply in receipt order

Applies to: `QueueRead.applying(to:)`, `removeProcessingMessage(_:receivedAt:)`

Buffered processing can be applied after a later local ACK. Receipt order, not
application order, decides the final rows. Only processing received after a
read started removes rows from its seed. Untouched rows survive without
extending the bounded reconciliation loop.

### 7. A complete reply supersedes a replayed earlier event

Applies to: `ConversationCommands.applyQueueEvent(_:receivedAt:)`

Delayed workspace validation can replay an event during a read that actually
started later. A complete reply supersedes that event.

### 8. The mutation journal exists only for buffered workspace events

Applies to: `QueueMutationHistory`, `confirmQueueMutation(_:generation:)`

Only buffered workspace events need a journal. Its lifetime belongs to the
shared conversation owner and ends when those events fold or cancel. A
completed ACK belongs to surviving owners even if its caller was cancelled in
the meantime. Final release or reset invalidates the generation.

### 9. Queue snapshot decoding

Applies to: `ConversationCommands.decodeQueueSnapshot(_:source:)`, `describeDecodingFailure(_:)`

One decoder serves `getQueue` and `queue:updated` (PROTOCOL §5.5). A non-array
returns nil. Invalid elements are dropped, and valid rows keep their order and
ids. Logs hold only array positions and error shapes (decoding case and path,
or the error type), never content or metadata. The optional collection return
is deliberate: nil preserves the current queue for malformed input, and an
empty array clears it.

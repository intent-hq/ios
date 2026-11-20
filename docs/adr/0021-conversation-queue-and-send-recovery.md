# 0021. Conversation queue and send recovery

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

A conversation has a daemon-side message queue (PROTOCOL §5.5) and sends that can time out after the daemon accepted them. Queue reads are paged and race events and local mutations.

## Decision

1. **Markers.** `pendingQuestionsMessageId` is a three-state marker: nil when absent (legacy daemon), `""` when nothing is pending, else the message id. It is never coerced.
2. **Send correlation.** `userAppMessageId` correlates auto-queue and drain. It is not a replay or dedup guarantee.
3. **Queue decoding.** `getQueue` and `queue:updated` share one decoder. A non-array keeps the current queue; a valid empty array clears it. Invalid elements are dropped and valid rows keep their order and ids. Logs carry only positions and error shapes, never content or metadata.
4. **Paged queue reads (`fetchQueue(agentId:)`).**
   1. Positions are whole-queue, and the page token is a position. A walk overtaken by a queue event, processing removal, local mutation, reset or newer read stops without publishing. The daemon's next `agent:queue:updated` carries the whole queue; a re-read starts at page one.
   2. Drains and local edits shift positions even when they fold into the read. A change during the last page can shift it too. A single page is one snapshot, so its folded changes still apply.
   3. Later acknowledged changes and processing removals fold in without dropping unrelated seed rows. Only processing received after a read started removes rows from its seed.
   4. Delayed workspace validation can replay an event during a later read; a complete reply supersedes it.
5. **Mutation history.** Only buffered workspace events need `QueueMutationHistory`. It belongs to the shared conversation owner and ends when the events fold or cancel. A completed ACK belongs to surviving owners even if its caller was cancelled; final release or reset invalidates the generation. Receipt order, not application order, decides the final rows.
6. **Queue seed.** A queued send seeds a row only if no newer queue event or read landed and no transcript echo won.
7. **Send recovery.**
   1. `beginSendAttempt(…)` runs before placement suspends. Every send gets a new identity, even with the same text as an older failure.
   2. An authoritative echo can beat a timeout. Positive acceptance is never demoted to uncertainty.
   3. An oversized selection must be edited, not replayed.
   4. Only app-owned pre-dispatch provenance proves non-delivery. A remote RPC can reuse WebSocket code -4; the code alone is not proof.
   5. `reconcileSendAttempts(messages:)` uses positive rows only. Missing pages, malformed reads, projected queues and absent ids are never evidence that a mutation did not happen.
   6. The top-level `appMessageId` wins over a nested legacy metadata copy. A present correlation is exclusive, including unknown ids; only its absence allows direct or confirmed row identity. A row that names different attempts settles none.
   7. RPC acceptance is terminal for status, not for transcript identity. Only authoritative rows refine an accepted association.
   8. `inspectSendAttempt(_:)` is read-only and user-triggered. It never resends. It can confirm a row but cannot turn an absent row into a safe retry. It reconciles only response rows.

## Code

- `ConversationCommands`: `AgentState.pendingQuestionsMessageId`, `fetchQueue(agentId:)`, `queueMessage`, `fetchMessage`
- `ConversationCommands` (queue events): `QueueMutationHistory`, `QueueReadSuperseded`, `decodeQueueSnapshot(_:source:)`, `applyQueueEvent(_:receivedAt:)`, `removeProcessingMessage(_:receivedAt:)`
- `ConversationStore` (send recovery): `beginSendAttempt(…)`, `confirmSendAttempt`, `reconcileSendAttempts(messages:)`, `inspectSendAttempt(_:)`

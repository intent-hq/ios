# ADR-0506: Conversation send attempts: identity, failure status, and reconciliation

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationStore` send recovery (`Intent/Services/ConversationStore+SendRecovery.swift`)

## Context

A send can fail, time out, or be confirmed by several sources: the RPC reply, a
transcript echo, a queue snapshot, or a user-triggered status check. The store
tracks each send as a `ConversationSendAttempt` and must never claim a send was
not delivered without proof.

## Decisions

### 1. Every send gets a new identity before it suspends

Applies to: `beginSendAttempt(agentId:content:workspaceId:images:files:fileAccess:messageMetadata:)`

It is called before attachment placement suspends. A new send always gets a new
identity, even when its text matches an older failure.

### 2. Positive evidence is never demoted

Applies to: `sendPreparedAttempt(_:)`

An authoritative echo may beat a timeout or error response. That positive
acceptance evidence is never demoted back to uncertainty.

### 3. Only app-owned pre-dispatch failures prove non-delivery

Applies to: `sendPreparedAttempt(_:)`

Only app-owned pre-dispatch provenance (`DiagnosticErrorOwnership` origin
`localRequest` with `notConnected`) marks an attempt `notSent`. A remote RPC can
reuse WebSocket/-4, so its code alone is not proof; other failures are
`unconfirmed`. An `OutgoingImagePayload.RequestError` clears `isPrepared`,
because the selection must be edited, not replayed at the same size.

### 4. Reconciliation uses positive rows only

Applies to: `reconcileSendAttempts(messages:)`, `reconcileSendAttempts(queue:)`

Missing pages, malformed reads, projected queues, and absent ids are never
evidence that a mutation did not happen.

- `AgentMessage` reads lift `appMessageId` out of row metadata. A nested legacy
  `userAppMessageId` copy must not override the canonical top-level
  correlation.
- RPC acceptance is terminal for status, not for transcript identity. Only
  authoritative rows may refine an already accepted association; late RPC or
  queue results still stop at the guard in `confirmSendAttempt`.

### 5. Row-to-attempt matching

Applies to: `sendAttemptId(rowId:appMessageId:)`

A present correlation id is exclusive, including unknown ids. Only its absence
permits direct or previously confirmed row identity. Matches count attempts,
not matching fields: two identities on one attempt are fine, but a row that
names different attempts settles none.

### 6. Status checks are read-only

Applies to: `inspectSendAttempt(_:)`

The check is read-only and explicitly user-triggered; it never resends a
mutation. It can confirm a matching row, but cannot turn an absent row into a
safe retry. `fetchQueue` reconciles only the response rows, not cached or
optimistic data.

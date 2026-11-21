# ADR-0025: Agent questions are wizard-only, keyed by the daemon's pending marker, and answered with one tagged message

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `QuestionOption`, `Question`, `PendingQuestionSet`,
  `QuestionAnswer`, `ConversationMessage.answeredQuestionsMessageId`,
  `QueuedMessage.answeredQuestionsMessageId` (`Intent/Models/Question.swift`)

## Context

An agent can ask the user structured questions with `ws.app.question.ask`. The
composer slot shows a wizard for the pending set, and the user's answers go back
as a message. The web client (cloudlands-fe) has the same feature. Both clients
must agree on when a set is pending, answered, or dismissed.

## Decisions

### 1. Question resources and their wire contract

Applies to: `Question`, `QuestionOption`, `Question.isQuestionResourceBlock(_:)`,
`Question.question(from:)`

A question is an Agent Q&A resource (PROTOCOL §7.1 standalone resource block).
The daemon attaches one resource block per `ws.app.question.ask` call as a
trailing block on the turn's final assistant message. There is no question id:
pending versus answered is keyed on the question-bearing assistant message id
through the daemon's session-metadata marker (PROTOCOL §5.5
`pendingQuestionsMessageId`), with a transcript-tail fallback for legacy
sessions.

Questions are wizard-only. They never render in the conversation transcript,
pending or resolved. The model mirrors the cloudlands-fe contract in
`src/shared/types/question-resource.ts`.

- `attachmentId` is the turn-attachment registry id (`tar-…`) stamped by the
  daemon.
- `header` is a short category label rendered above the question (for example
  "Auth method"). `explanation` is optional longer context shown expandable.
- `options` holds at least 2 options. A free-form "Other" answer is implicit and
  always offered. An absent `multiSelect` on the wire means single-select.

Decoding is strict and identical to the web `isQuestion` and
`isQuestionOption`:

- `QuestionOption`: `label` must be a non-empty string. `description` is absent
  or a string; `null` is rejected.
- `Question`: `attachmentId` is any string, with no length check (web parity).
  `header` and `question` are non-empty strings. `explanation` is absent or a
  string; `null` is rejected. `options` is an array of at least 2 valid
  options. `multiSelect` is absent or a boolean; `null` and numbers are
  rejected.

`isQuestionResourceBlock` checks the MIME type only. Payload validity does not
matter there: even a malformed question payload must not surface in the
transcript (web parity: `isQuestionResourceBlock`). `question(from:)` returns
`nil` when the MIME type does not match or the payload is malformed (web
parity: `getQuestionFromResourceBlock`, including the legacy
`metadata.resource` fallback).

Question resource blocks must survive both decode paths: snapshot transcript
rows and live block deltas.

A set holds its questions in transcript order, deduplicated by `attachmentId`
(the first is kept). A change to the question schema must change the web
client and the app together.

### 2. The daemon's three-state marker decides what is pending

Applies to: `PendingQuestionSet`, `PendingQuestionSet.MarkerState`,
`PendingQuestionSet.derive(...)`

`PendingQuestionSet` is a port of the web `derivePendingQuestions` in
`chat/questions/pending-questions.ts`. `messageId` is the id of the
question-bearing assistant message, and it keys wizard remounts.
`MarkerState` keeps "absent" and "written empty" distinct (web parity:
`classifyPendingQuestionMarker`).

The marker is authoritative when present. An empty string clears the slot. A
message id permits only that question-bearing row, and keeps it pending across
later automatic or user turns until the daemon clears it (answer or dismissal).

With the marker set, the marked row stays pending regardless of
`isTurnActive`: the marker is only written once the asking turn has ended, and
later turns must not hide the wizard. The set is `nil` only while that row is
still streaming (or is missing, is not an assistant row, or carries no valid
question), once a tagged answer row names it, or while an optimistic pending
user bubble is shown.

`queuedAnsweredQuestionsMessageIds` are the question sets answered by sends
that are not in the transcript yet. The daemon auto-queued the tagged answer
during an active turn, so the only local `question_answers` tag lives on the
queue entry (`QueuedMessage.answeredQuestionsMessageId`). A marked set named
there is treated as answered exactly like a tagged user row, so the wizard
cannot pop back in and take a duplicate submission before the queued answer is
delivered. Callers pass the ids in; the helper does not read the store.

### 3. Legacy sessions use the daemon's transcript-tail fallback

Applies to: `PendingQuestionSet.deriveLegacySet(...)`

Without the marker (legacy daemon), the transcript-tail fallback applies. It is
also `nil` whenever the agent's own turn is active (`isTurnActive`). This
matches the daemon's pre-marker fallback: trailing system rows are transparent,
and only a question-bearing assistant row at the non-system tail is pending.
Any trailing user message supersedes it.

### 4. A dismissed set never pends again

Applies to: `PendingQuestionSet.questionSet(from:dismissedQuestionsMessageId:)`

In both paths a question set the user dismissed never pends. The daemon
persists the dismissed message id in session metadata (`agent.dismissQuestions`,
PROTOCOL §5.5 `dismissedQuestionsMessageId`). When it matches the
question-bearing message, the set is retired, and this survives reload. A newer
question-bearing message (a different id) pends normally. Web parity:
`wizard-gate.ts` / `isQuestionMessageDismissed`.

### 5. The answer tag bridges the gap until the daemon clears the marker

Applies to: `PendingQuestionSet.isQuestionSetAnswered(messages:messageId:)`,
`ConversationMessage.answeredQuestionsMessageId`,
`QueuedMessage.answeredQuestionsMessageId`

A set is answered when a user row carries the wizard's answer tag
(`{ type: "question_answers", answeredQuestionsMessageId }`) naming it. This
bridges the window between the user tapping Send (the optimistic row mirrors
the tag) and the daemon's `agent:updated` clearing the marker, so an answered
set never pops back in (web parity: `isQuestionSetAnswered`).

`ConversationMessage.answeredQuestionsMessageId` reads the row's `metadata`
first, then the text blocks' `messageMetadata`. This is the same dual surface
the daemon persists a tagged message on (see `QuestionsDismissedNotice`). Web
parity: `getAnsweredQuestionsMessageId`.

`QueuedMessage.answeredQuestionsMessageId` exists because the daemon auto-queues
the tagged answer when it is sent during an active turn. Until it is delivered,
the queue entry's `messageMetadata` is the only local copy of the
`question_answers` tag, because the optimistic transcript row is removed on
`queued: true`.

### 6. Answers are flattened into one plain-text message

Applies to: `QuestionAnswer`, `QuestionAnswer.flattenToMessage(_:)`

This is the wire contract, and a port of the web
`chat/questions/answer-message.ts`. All answers of a question set collapse into
one plain-text user message of `Q:` / `A:` pairs separated by a blank line.
Multi-select answers are comma-joined (in selection order), free-form replies
are prefixed `(Other)`, and skipped questions are reported as `(skipped)`. The
message travels through the ordinary `agent.sendMessage` path, tagged with
`messageMetadata { type: "question_answers", answeredQuestionsMessageId }`. The
structured tag, never the answer text, resolves the pending set on the daemon.

A question left unanswered without an explicit Skip is only reachable through
Back-then-Send edge flows. It reads the same as a skip on the wire.

# 0056. Agent question resource contract

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Agents ask the user structured questions with `ws.app.question.ask`. The app shows them in a wizard in the composer slot. [ADR 0004](0004-agent-questions-gating.md) records how pending questions gate the composer. This record holds the wire contract of the question payload and the answer, which mirror cloudlands-fe `src/shared/types/question-resource.ts`, `chat/questions/pending-questions.ts` and `chat/questions/answer-message.ts`.

## Decision

1. **Resource block.** The daemon attaches one standalone resource block (PROTOCOL §7.1) per `ws.app.question.ask` call, as a trailing block on the turn's final assistant message. Its MIME type is `application/vnd.intent.question+json`.
2. **No question id.** Pending and answered are keyed on the question-bearing assistant message id, through the session marker `pendingQuestionsMessageId` (PROTOCOL §5.5). Legacy sessions use the transcript-tail fallback.
3. **Wizard only.** Questions never render in the transcript, pending or resolved. The check is MIME-only, so even a malformed payload stays out of the transcript (FE `isQuestionResourceBlock`).
4. **Strict decode** (FE `isQuestion`, `isQuestionOption`).
   1. `attachmentId` (the daemon's `tar-…` registry id) is any string.
   2. `header` and `question` are non-empty strings. `explanation` is absent or a string; null is rejected.
   3. `options` is an array of at least two valid options. "Other" free text is always offered and is not an option.
   4. An option `label` is a non-empty string; `description` is absent or a string.
   5. `multiSelect` is absent (single select) or a boolean; null and numbers are rejected.
   6. `question(from:)` also reads the legacy `metadata.resource` location (FE `getQuestionFromResourceBlock`).
   7. A set holds its questions in transcript order, deduplicated by `attachmentId` (first kept).
5. **Derivation** (`PendingQuestionSet.derive`, FE `derivePendingQuestions`). The rules are in ADR 0004. In addition:
   1. The marker classification keeps "absent" and "written empty" apart (`MarkerState`, FE `classifyPendingQuestionMarker`).
   2. Legacy fallback: like the daemon's pre-marker rule, trailing system rows are transparent, and the first non-system row must be a question-bearing assistant message. Any user row supersedes it.
   3. A dismissed set never pends: the daemon persists `dismissedQuestionsMessageId` (`agent.dismissQuestions`), and a newer question message pends normally (FE `wizard-gate.ts`).
   4. A user row with the answer tag naming the set marks it answered. This covers the time between Send and the daemon's `agent:updated` (FE `isQuestionSetAnswered`). The tag is read from row `metadata`, then block `messageMetadata` (FE `getAnsweredQuestionsMessageId`).
   5. While an answer sent during a turn is auto-queued, the queue entry's `messageMetadata` is the only local copy of the tag, because the optimistic row is removed on `queued: true`. `QueuedMessage.answeredQuestionsMessageId` reads it, and callers pass those ids to `derive`.
6. **Answer message** (FE `answer-message.ts`). All answers of a set become one plain-text user message of `Q:`/`A:` pairs separated by a blank line. Multi-select answers are comma-joined, free text is prefixed `(Other)`, and skipped questions read `(skipped)`. A question left empty without an explicit Skip also reads `(skipped)`. The message uses the ordinary `agent.sendMessage` path with the `question_answers` tag; the tag, never the text, resolves the set.

## Consequences

- A payload the FE would reject is also rejected here, and it never leaks into the transcript.
- Changes to the question schema must change the FE and the app together.

## Code

- `Question`: `resourceMimeType`, `init(from:)`, `isQuestionResourceBlock(_:)`, `question(from:)`
- `QuestionOption`: `init(from:)`
- `PendingQuestionSet`: `derive(…)`, `MarkerState`, `isQuestionSetAnswered(…)`
- `ConversationMessage.answeredQuestionsMessageId`, `QueuedMessage.answeredQuestionsMessageId`
- `QuestionAnswer`: `flattenToMessage(_:)`

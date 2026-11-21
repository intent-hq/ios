# ADR-0012: Agent Q&A pending questions follow the daemon marker

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationViewModel` Q&A (`Intent/ViewModels/ConversationViewModel+Questions.swift`)
- Related issues: intent-hq/intent#3936

## Context

An agent can ask a set of questions. The composer slot then shows a wizard
instead of the ordinary composer. The daemon tracks which question set is
pending (PROTOCOL §5.5). Older daemons do not, and the marked row can be
outside the loaded transcript page.

## Decisions

### 1. The daemon marker is authoritative and sticky

Applies to: `ConversationViewModel.pendingQuestions`

When the daemon's `pendingQuestionsMessageId` marker is present, it is
authoritative. The marked set appears once the asking turn ends and stays
sticky across later turns: automatic deliveries or a plain user message do not
hide it. It hides only when:

1. a user row carries the `question_answers` tag naming it. The optimistic
   answer row appended by `submitQuestionAnswers` carries the tag, so Send hides
   it at once. When the daemon auto-queues that answer mid-turn, the tag is on
   the queue entry instead, which counts the same;
2. it is dismissed (the `agent.dismissQuestions` marker); or
3. the daemon clears the marker to `""`.

With a legacy daemon (marker absent), the transcript-tail fallback applies:
nil while the turn is active (`isStreaming`) or once a later user message
supersedes it. A failed wizard send is rolled back
(`ConversationStore.rollbackFailedSend`) so unanswered questions re-pend in both paths.

### 2. A recovered copy stands in for a non-resident marked row

Applies to: `ConversationViewModel.pendingQuestions`, `nonResidentMarkedMessageId`, `recoveredMarkedMessage`

When the marked row is outside the loaded page, the copy recovered by the
store's targeted seek (`pendingQuestionRecovery`, status `found`) is prepended
to the transcript for the derivation. The marker path finds it, the tail is
still scanned for the tagged answer row, and the queued-answer and dismissal
bridges apply unchanged. A resident row always wins over the recovered copy
(FE parity: `wizard-gate.ts` `deriveWizardPendingQuestions`).

Both recovery-aware derivations key off `nonResidentMarkedMessageId`, the
marker's id when it names a row that is not in the loaded transcript. The
recovered copy is used only when the seek settled `found` for the current
marker id and the row is still not resident. A stale recovery for another id,
or one superseded by the row arriving, is ignored.

### 3. The composer slot fails closed during recovery

Applies to: `ConversationViewModel.isPendingQuestionRecoveryLoading`, `suggestedPrompts`

The gate is true while the marker names a non-resident row and no recovered
wizard can be rendered from it: the seek is in flight, settled
`notFound`/`error`, or found a row without a valid question set. Exhausted
retries end the network attempts, not the marker's authority. The ordinary
composer and suggested prompts stay withheld until the daemon clears or
replaces the marker (FE parity: `deriveMarkedQuestionRecoveryState` and
`ChatPanel`'s `pendingQuestionRecoveryLoading`).

The gate is false until the initial transcript fetch has settled, because the
row may simply not have loaded yet. It is false once a recovered wizard exists,
even if it is answered or dismissed.

Suggested prompts stay hidden whenever the turn has pending questions,
including while the wizard is Ignore-collapsed, and while the marked row is
being recovered. Only answering, or any superseding user message, brings them back.

### 4. Answers are one tagged message

Applies to: `ConversationViewModel.submitQuestionAnswers(_:answeredQuestionsMessageId:)`

The wizard's answers are flattened into one user message of `Q:`/`A:` pairs and
sent through the ordinary send path, tagged with
`messageMetadata { type: "question_answers", answeredQuestionsMessageId }`,
together with the question set's attachments. The structured tag, never the
answer text, makes the daemon retire the question hold and demote
`needs_attention` (FE parity: `answer-message.ts`, `ChatPanel`).

`answeredQuestionsMessageId` is the wizard's mount-time question-bearing
assistant message id (the wizard is `.id`-keyed on it). It is passed in, not
re-derived, so a derivation flip between the tap and the main-actor hop (a
pushed stream start, a superseding row from another client) can never send the
answer untagged.

Upload failures keep the selection for retry. A successful send retires only
this question set's attachments, never the composer's.

### 5. Submission checks remote retirement after uploads

Applies to: `ConversationViewModel.submitQuestionAnswers(_:answeredQuestionsMessageId:)`, `questionSubmissionIsCurrent(_:pendingMarker:)`

- A late submit for an older mount must not replace a newer card's selection,
  so it uses a fresh pipeline when none exists for its id.
- Uploads suspend before the optimistic answer exists. Remote retirement must
  win here, even though the view lifecycle exempts submitting ids.
- With a legacy daemon, streaming alone can hide a wizard, but a superseding
  non-system transcript row retires its mount-time question set.

### 6. Each question set owns its attachments

Applies to: `ConversationViewModel.questionAttachments(for:)`, `discardQuestionAttachments(for:)`

A question set owns its attachment selection independently of the ordinary
composer and other question sets. It is reused across wizard remounts and
failed sends. Creating one for a new message id discards the superseded ones.

### 7. Dismissal is persistent

Applies to: `ConversationViewModel.dismissQuestions(messageId:)`

Dismissing without answering (`agent.dismissQuestions`) is persistent. Unlike
Ignore's transient collapse, the daemon-persisted marker means the set never
re-pends, even after reload. `messageId` is the wizard's mount-time id, with the
same capture discipline as `submitQuestionAnswers`. A failed RPC leaves the
wizard pending (the store rolls the optimistic marker back) and sets `dismissQuestionsError`.

### 8. Prompts and stripping come from one scan

Applies to: `ConversationViewModel.suggestedPrompts`

Suggested prompts use the same message-level scan the views use for stripping
(an empty join, like the desktop, so mid-line splits reassemble). Prompts and
stripping come from one scan and can never disagree (intent-hq/intent#3936;
`SuggestedPrompts.parse(contentBlocks:)`).

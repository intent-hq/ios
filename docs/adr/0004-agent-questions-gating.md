# 0004. Agent Q&A pending questions gate the composer

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

An agent can ask a set of questions. The composer slot then shows a wizard in place of the ordinary composer. The daemon marks the set with `pendingQuestionsMessageId` (PROTOCOL §5.5). Older daemons do not send the marker. The marked row can be outside the loaded page of the transcript. The app must match the desktop (`wizard-gate.ts`, `deriveWizardPendingQuestions`, `deriveMarkedQuestionRecoveryState`, `answer-message.ts`).

## Decision

1. **The marker is the authority.**
   1. When the marker is present, the marked set shows once the asking turn ends. It stays across later turns: automatic deliveries and plain user messages do not hide it.
   2. It hides only when a user row carries the `question_answers` tag that names it, when it is dismissed (`agent.dismissQuestions`), or when the daemon clears the marker to `""`. An answer that the daemon queued mid-turn carries the tag on the queue entry, and that counts the same.
   3. **Legacy daemons (no marker):** the transcript tail decides. The set is hidden while the turn streams, or once a later non-system row supersedes it.
   4. A failed wizard send rolls back (`ConversationStore.rollbackFailedSend`), so the questions show again in both paths.
2. **Recovery fails closed.**
   1. When the marked row is not loaded, the store seeks it (`pendingQuestionRecovery`). A `found` copy for the current marker id is prepended for the derivation. A loaded row always wins over the recovered copy. A recovery for another id is ignored.
   2. While the seek runs, or after it settles `notFound`/`error`, or finds no valid set, the ordinary composer and suggested prompts stay hidden (`isPendingQuestionRecoveryLoading`). Retries that run out end the network attempts, not the marker's authority.
   3. The gate is open until the first transcript fetch settles, and once a recovered wizard exists.
3. **Answers.**
   1. The wizard sends one user message of `Q:`/`A:` pairs through the ordinary send path, tagged `{ type: "question_answers", answeredQuestionsMessageId }`. The tag, not the text, makes the daemon release the question hold and demote `needs_attention`.
   2. `answeredQuestionsMessageId` is the wizard's mount-time id, passed in by the view. The model never derives it again at send time, so a stream start or a superseding row between the tap and the send cannot send the answer untagged.
   3. Uploads suspend before the optimistic answer exists. After they finish, the send checks again that the set is still current. A remote retirement wins, also for a set that the view marks as submitting.
   4. Each question set owns its attachments, apart from the composer and other sets. The selection survives wizard remounts and failed sends. A late submit for an older mount does not replace a newer card's selection. Success retires only that set's attachments.
4. **Dismissal** persists in the daemon, so the set does not come back after reload. It is not Ignore, which only collapses the wizard. A failed RPC rolls the optimistic marker back and shows `dismissQuestionsError`.
5. **Suggested prompts** stay hidden while questions are pending (also when the wizard is collapsed) and while recovery is loading. Prompts and the text that the views strip come from one scan (`SuggestedPrompts.parse(contentBlocks:)`, intent-hq/intent#3936), so they cannot disagree.

## Code

- `ConversationViewModel` (`+Questions`): `pendingQuestions`, `isPendingQuestionRecoveryLoading`, `submitQuestionAnswers(…)`, `questionSubmissionIsCurrent(_:pendingMarker:)`, `dismissQuestions(messageId:)`, `questionAttachments(for:)`, `suggestedPrompts`
- `PendingQuestionSet.derive(…)`, `SuggestedPrompts`

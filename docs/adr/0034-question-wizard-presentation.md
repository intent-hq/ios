# 0034. Question wizard presentation and attachments

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

[ADR 0004](0004-agent-questions-gating.md) decides when a question set gates the composer and how answers are sent. This record covers how the wizard is presented and how its attachments live. The wizard shows in the composer slot or, in the workspace design, in a floating panel over the live conversation. It can collapse, remount, stream behind, or roll back after a failed send.

## Decision

1. **Mounting.**
   1. The host remounts `QuestionWizardView` whenever a different question set pends.
   2. `WorkspaceQuestionPresentation` keeps the live conversation mounted under a deliberate, blocking answer surface.
   3. `QuestionCardPager` keeps only the selected card mounted. SwiftUI keeps the departing card for its transition, then removes its controls from the accessibility tree. `QuestionCardLayout` gives each page the full width and its natural height; only the selected page sets the container height, so height and position animate together.
2. **Fit.** `WorkspaceQuestionStepView` measures the complete native content, controls included, at the proposed width. The host supplies the remaining question region, not a screen-size breakpoint. The fit candidates hold only stateless controls; the free-text editor lives outside the panel, so a layout change cannot replace its first responder. The last candidate scrolls all content so the footer stays reachable. Answers stay stacked even when the keyboard reduces the height.
3. **Free text.** The free-text answer reuses `SubmittableTextView`, so Return follows `ComposerSubmitPolicy` ([ADR 0030](0030-conversation-composer-input.md)). The return-key hint shows only where bare Return submits. `showsNext(isMulti:isLast:hasFreeText:)` shows the footer Next/Send button where Return inserts a newline, because that button is then the submit path.
4. **Submit.**
   1. Completing the last step while the Mac is offline (remote read-only) does nothing. The answers wait in the drafts.
   2. With pending attachments, the panel stays mounted during upload and the optimistic answer row, so progress and retryable drafts stay visible. A failed RPC does not reset the wizard.
   3. Without attachments, the banner stays mounted for the matched transition, but fades and releases its reserved height as the panel closes, before the send.
5. **Attachments.**
   1. Retirement is not disappearance. Streaming and a collapsed card keep the drafts (`QuestionAttachmentLifecycle`).
   2. `retiredQuestionAttachmentMessageIds` reads every signal even before the first pipeline exists. The pipeline dictionary is not observable on purpose.
   3. A set that is submitting is never retired here; its optimistic answer can roll back, and the send owns cleanup.
   4. Without a daemon marker, a legacy turn can hide its question-bearing tail while it streams, so the set is not retired then.
   5. Imports belong to the question set, not to its presentation. Remote retirement and a successful submit cancel them in the owner.
   6. Image previews use the index, as the composer does, so the same image can be attached twice.
   7. Options have no wire id. The option index is the selection contract, also for duplicate labels.

## Consequences

- Closing or collapsing the wizard never discards question attachments. Only retirement does.

## Code

- `QuestionWizardView`: `showsNext(isMulti:isLast:hasFreeText:)`, `advance()`
- `WorkspaceQuestionPresentation`: `submit(_:pending:)`, `WorkspaceQuestionPendingBanner`
- `QuestionCardPager`, `QuestionCardLayout`, `WorkspaceQuestionStepView`, `QuestionStepView`
- `QuestionAttachmentLifecycle`, `ConversationViewModel.retiredQuestionAttachmentMessageIds`, `QuestionAttachmentPickers`, `QuestionAttachmentTray`, `WorkspaceQuestionAnswerCards`

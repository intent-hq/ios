# ADR-0901: Question wizard answers, drafts, and attachments

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `QuestionWizardView` (`Intent/Views/Conversation/Questions/QuestionWizardView.swift`), `QuestionWizardFooterRow` (`Intent/Views/Conversation/Questions/QuestionWizardFooterRow.swift`), `QuestionStepView` (`Intent/Views/Conversation/Questions/QuestionStepView.swift`), `QuestionAttachmentLifecycle` and `ConversationViewModel.retiredQuestionAttachmentMessageIds` (`Intent/Views/Conversation/Questions/QuestionAttachmentLifecycle.swift`), `QuestionAttachmentPickers` (`Intent/Views/Conversation/Questions/QuestionAttachmentPickers.swift`), `QuestionAttachmentTray` (`Intent/Views/Conversation/Questions/QuestionAttachmentTray.swift`)

## Context

An agent can ask the user a set of questions. `QuestionWizardView` walks the
user through them one step at a time and sends the answers to the Mac. Each
question set can carry its own attachments.

## Decisions

### 1. The host remounts the wizard for each question set

Applies to: `QuestionWizardView`

The wizard is a sequential Agent Q&A wizard. It renders in the composer slot or
in the floating workspace panel. The host remounts it whenever a different
question set pends, so the wizard does not reset its own drafts.

### 2. `workspaceAvailableHeight` opts in to the floating panel

Applies to: `QuestionWizardView.workspaceAvailableHeight`

Only the floating workspace panel sets this value. It is the panel's
keyboard-safe available height. `nil` keeps the shared composer-slot behavior.

### 3. The Next/Send button is the submit path for free text on single-select steps

Applies to: `QuestionWizardView.showsNext(isMulti:isLast:hasFreeText:)`

On a single-select step, free text has no option tap that advances the wizard.
Where `ComposerSubmitPolicy` makes Return insert a newline (iPhone), Return
cannot submit either. So the footer shows Next/Send whenever there is free text.

### 4. Answers wait in the drafts until the Mac is back

Applies to: `QuestionWizardView.advance()`

On the last step, `advance()` does not send while the remote session is
read-only, while a send is running, or after dismissal. The answers stay in the
drafts until the Mac is back.

### 5. Skip and Send on the last step send the answers

Applies to: `QuestionWizardFooterRow.sendsAnswers`

On the last step, both Skip and Send send the answers to the Mac. That is why
`sendsAnswers` equals `isLast` and both buttons are disabled while the remote
session is read-only.

### 6. The free-text field reuses the composer's text view

Applies to: `QuestionStepView.otherField`, `QuestionStepView.freeTextLineHeight`,
`QuestionStepView.clampedFreeTextHeight(_:lineHeight:)`,
`QuestionStepView.textContainerVerticalInsetMultiplier`

The multiline free-text answer reuses the composer's `SubmittableTextView`. So
hardware Return submits and Shift+Return inserts a newline under the same
`ComposerSubmitPolicy` as the composer. The return-key hint shows only where
bare Return really submits (`KeyCommandTextView.returnSubmitsNow`).

One body line is measured with the font that `SubmittableTextView` installs.
The field height is clamped between one line and `freeTextMaximumLineCount`
lines, plus the text container insets. Past the cap the text view scrolls.
`textContainerVerticalInsetMultiplier` is 2 because the text container has a
top and a bottom inset. It is not a visual scale.

### 7. Attachments belong to the question set, not to its presentation

Applies to: `QuestionAttachmentPickers`, `QuestionAttachmentTray`,
`QuestionAttachmentLifecycle`

The question attachments are one selection shared by every step, separate from
the conversation composer. Imports belong to the question set, not its
transient presentation. Remote retirement and successful submission cancel
them in the owner (`ConversationViewModel`).

Retirement is not disappearance. Streaming and a collapsed card keep the
drafts. `QuestionAttachmentLifecycle` discards a pipeline only when its
message id is in `retiredQuestionAttachmentMessageIds`.

### 8. Rules for retiring a question set's attachments

Applies to: `ConversationViewModel.retiredQuestionAttachmentMessageIds`

1. The property reads all its signals before it filters, even before the first
   pipeline exists. The pipeline dictionary itself is intentionally not
   observable, so the signals are what make the property update.
2. A question set that is being submitted is never retired. Its optimistic
   local answer row may roll back, and the send owns cleanup.
3. When the pending-questions marker is absent, a legacy turn can temporarily
   hide its question-bearing tail. The set is retired only when nothing streams
   and the last non-system message is a different, finished message.

### 9. The photo picker never receives a zero limit

Applies to: `QuestionAttachmentPickers.body(content:)`

Photos interprets a `maxSelectionCount` of zero as unlimited. The limit is
clamped to at least 1. The attachment menu disables Photos when no image slot
is left.

# ADR-0914: Conversation column composer, question presentation, and status rows

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ConversationColumnView`, `ConversationHeaderBackdrop`, `ConversationBackground` (`Intent/Views/Conversation/Transcript/ConversationColumnView.swift`), `ConversationView` (`Intent/Views/Conversation/Transcript/ConversationView.swift`)

## Context

`ConversationColumnView` stacks the transcript, the status rows below it, the
question region, and the composer. Pending questions and the composer compete
for the same slot, and visionOS presents both differently from iOS.

## Decisions

### 1. visionOS presents questions in a sheet; the inline slot shows only an opener

Applies to: `ConversationColumnView.questionSheetPresented`, `questionRegion`, `questionSheet`

On iOS the question wizard renders in the composer slot (or the floating
workspace panel, see ADR-0901). On visionOS it is a deliberate sheet
(`.sheet(isPresented: $questionSheetPresented)`). The inline slot shows only
`QuestionWizardCollapsedBanner`, whose expand action reopens the sheet.

The sheet opens by itself when a new question set pends, and closes when the
set clears (answered or dismissed elsewhere, or superseded). It does not toggle
while answers are being submitted (`submittingQuestions`).

### 2. `composerVisible` differs by platform

Applies to: `ConversationColumnView.composerVisible`

- **visionOS:** the wizard is in the sheet, so the composer stays available
  under the opener banner. It hides only while the marked question row is
  being recovered (`isPendingQuestionRecoveryLoading`), unless the wizard is
  collapsed. A `pendingQuestions != nil` check is not needed: a derived set
  means the marked row is resident or recovered, which implies
  `isPendingQuestionRecoveryLoading` is false.
  `PendingQuestionRecoveryExclusivityTests` pins this invariant.
- **iOS:** pending questions occupy the composer slot until the wizard is
  collapsed, and the composer also hides during recovery.

### 3. The composer slot fails closed during marked-row recovery

Applies to: `ConversationColumnView.questionRegion`

While the marked question row is recovered from outside the loaded page, the
slot shows `PendingQuestionRecoveryPlaceholder` and no composer. This holds
until the wizard can render or the daemon clears or replaces the marker. It
matches the desktop app's `ChatPanel` (`pendingQuestionRecoveryLoading`).
Collapsing still reveals the composer, as it does for a rendered wizard. The
gate itself is ADR-0111, decision 3.

### 4. Only an inline host builds the composer in the column

Applies to: `ConversationColumnView.body`

When `composerHost` is not `.inline`, the column builds no composer: the one
composer for the chat floats below the window in `FloatingComposerOrnament`
(ADR-0802). The conditional views use SwiftUI's default opacity transition.

### 5. Status rows stay reachable while the iPad wizard holds the composer slot

Applies to: `ConversationColumnView.accessoryRows`, `measuredAccessoryRows`

- Watch details (`MonitoredScriptsRow`) mount outside the composer and question
  slot, so answering questions does not unmount them.
- On iPad, the inline wizard occupies the composer slot. While it does, the
  column still shows the status pills and queued-message actions.
- On visionOS, the measured top of the status rows (`accessoryRowsTop`) keeps
  the workspace action launcher above them (ADR-0802, decision 6).

### 6. The column height is measured inside keyboard avoidance

Applies to: `ConversationColumnView.conversationHeight`

The height is measured inside the keyboard-avoiding container, so height caps
that use it get the height that is still visible above the keyboard.

### 7. Header backdrop and background ownership

Applies to: `ConversationHeaderBackdrop`, `ConversationBackground`

- On visionOS the transcript scrolls under the window's navigation bar, which
  draws no background. `ConversationHeaderBackdrop` puts a material band behind
  the bar that fades out just below it, so rows passing underneath blur instead
  of overlapping the bar.
- `ConversationBackground` is owned by the screen, outside its top safe-area
  inset, not by the transcript slot.

### 8. The dismiss-failure alert binding is a property, not built inline

Applies to: `ConversationView.dismissQuestionsErrorPresented`

The presented-or-not `Binding` for the dismiss-questions failure alert is
hoisted out of the `body` expression into its own property, so the type checker
does not have to solve the `Binding` construction inline.

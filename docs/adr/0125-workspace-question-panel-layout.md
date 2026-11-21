# ADR-0125: Workspace question panel layout and transitions

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `QuestionCardPager`, `QuestionCardLayout` (`Intent/Views/Conversation/Questions/QuestionCardPager.swift`), `WorkspaceQuestionStepView`, `QuestionHeightLimit` (`Intent/Views/Conversation/Questions/WorkspaceQuestionStepView.swift`), `WorkspaceQuestionAnswerCards` (`Intent/Views/Conversation/Questions/WorkspaceQuestionAnswerCards.swift`), `WorkspaceQuestionPresentation`, `WorkspaceQuestionSurface` (`Intent/Views/Conversation/Questions/WorkspaceQuestionPresentation.swift`), `WorkspaceQuestionPendingBanner` (`Intent/Views/Conversation/Questions/WorkspaceQuestionPendingBanner.swift`), `WorkspaceQuestionButtonStyle` (`Intent/Views/Conversation/Questions/WorkspaceQuestionButtonStyle.swift`), `WorkspaceQuestionFreeText` (`Intent/Views/Conversation/Questions/WorkspaceQuestionFreeText.swift`)

## Context

The workspace design shows pending questions as a banner above the composer.
Answering opens a floating panel. The panel must fit the space that the
keyboard leaves and animate between the banner and the panel.

## Decisions

### 1. The panel is a blocking surface over a live conversation

Applies to: `WorkspaceQuestionPresentation`

The live conversation stays mounted beneath a deliberate, blocking answer
surface.

### 2. Only the selected card is mounted

Applies to: `QuestionCardPager`

Only the selected card stays mounted. SwiftUI retains the departing card for
its transition, then removes its controls from the accessibility tree.

### 3. The selected page alone sets the pager height

Applies to: `QuestionCardLayout`

Each page gets the full width and its own natural height. Only the selected
page determines the container height. SwiftUI then interpolates the height and
the placements together. A `ZStack` was rejected because it holds the
departing page's taller height.

### 4. The step measures its complete native content against the host's region

Applies to: `WorkspaceQuestionStepView`, `WorkspaceQuestionStepView.content`,
`QuestionHeightLimit`

The step measures its complete native content, including controls, at the
proposed width. The host supplies the remaining question region, not a
screen-size breakpoint.

1. The `ViewThatFits` candidates contain only stateless controls. The free-text
   editor lives outside this panel, so a layout change cannot replace its
   responder.
2. The final candidate scrolls the complete content, so the footer stays
   reachable.
3. Answers stay stacked even when the keyboard reduces the available height.
4. `QuestionHeightLimit` offers the candidates a ceiling without expanding
   short content to that ceiling.

### 5. Answer cards are identified by index and built on the main actor

Applies to: `WorkspaceQuestionAnswerCards.cards`

Options are immutable for the mounted question and have no wire ID. Their index
is also the existing selection contract, including for duplicate labels.

SwiftUI can request a `ForEach` row off the main actor during fit and
transition work. So the cards are built first, and the `@Sendable` row closure
only transfers prepared view values. Actions and environment reads stay in the
main-actor card, not in the framework's row-provider callback.

### 6. Matched geometry moves the surface; content matches position only

Applies to: `WorkspaceQuestionSurface`

The surface changes size while its whole contents travel with its top edge.
The content matches position only, so the header and controls keep their
natural sizes.

### 7. Submit keeps the right things mounted

Applies to: `WorkspaceQuestionPresentation.submit(_:pending:)`,
`WorkspaceQuestionPendingBanner`

1. When the set has pending attachments, the panel stays open. Attachment
   progress and retryable drafts stay mounted during upload and the optimistic
   answer row. A failed RPC must not reset the wizard.
2. Otherwise the banner stays mounted for the matched transition. It fades and
   releases its reserved height while the panel closes, before the send.
3. The banner returns its reserved space during the panel closure, not in a
   second layout animation after the answers are sent.

### 8. Question controls have their own styles

Applies to: `WorkspaceQuestionButtonStyle`, `WorkspaceQuestionFreeText`

Question actions use the workspace palette without restyling shared buttons.
`WorkspaceQuestionFreeText` lets the native field lay out its prompt, caret,
and multiline answer together.

# ADR-0813: Row content is prepared on the main actor before row providers run

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ProposalCardView` (`Intent/Views/Conversation/Content/ProposalCardView.swift`), `WorkspaceLinkedTextView` (`Intent/Views/Conversation/Content/WorkspaceLinkedTextView.swift`), `AssistantHistoryMenu` (`Intent/Views/Conversation/AssistantView.swift`)

## Context

SwiftUI may request `ForEach` and menu rows off the main actor. These views
build rows that depend on main-actor state.

## Decisions

### 1. Build row values on the main actor; the row provider only returns them

Applies to: `ProposalCardView`, `WorkspaceLinkedTextView.body`, `AssistantHistoryMenu`

Each view reads its state on the main actor and builds an array of prepared
row values. The `ForEach` row provider is `@Sendable` and returns only those
prepared values.

1. `ProposalCardView` reads selection and store state on the main actor, not
   in the row provider.
2. `WorkspaceLinkedTextView` resolves workspace availability on the main
   actor, outside row providers.
3. `AssistantHistoryMenu`: SwiftUI may request menu rows off the main actor,
   so the provider returns only prepared values.

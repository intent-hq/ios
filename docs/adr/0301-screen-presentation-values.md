# ADR-0301: Screen presentation values hold one modal plus independent side state

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AgentConversationPresentation` (`Intent/Presentation/AgentConversationPresentation.swift`), `QuestionWizardPresentation` (`Intent/Presentation/QuestionWizardPresentation.swift`), `WorkspaceChromePresentation` (`Intent/Presentation/WorkspaceChromePresentation.swift`)

## Context

Several screens show sheets, alerts, pickers or drawers. Each screen keeps one
value type that owns what is open, instead of one Bool per sheet.

## Decisions

### 1. At most one modal is open per screen

Applies to: `AgentConversationPresentation.Modal`, `QuestionWizardPresentation.Modal`, `WorkspaceChromePresentation`

Each value has one optional modal (or the `none` case), so at most one of its
sheets, alerts, pickers or drawers is open.

- The agent conversation screen: model picker, rename, delete confirmation,
  note sheet and the demo cover.
- The question wizard: photo picker, file importer and dismiss confirmation.
- The workspace list chrome: the connection switcher drawer (`switcher`), the
  Create Workspace sheet and the Connections sheet. `RootView` (regular width)
  and `WorkspaceListView` (compact width) each hold one value and change it only
  through its methods.

### 2. Binding setters clear only the modal that is closing

Applies to: `AgentConversationPresentation.dismiss(_:)`, `QuestionWizardPresentation.setPresenting(_:_:)`, `WorkspaceChromePresentation.setPresenting(_:_:)`, and the `Binding.presenting(_:)` helpers

A binding setter clears the modal only while that modal is still the open one.
A late `false` from a closing sheet or drawer therefore cannot close its
successor.

### 3. State that outlives a modal is kept next to it, not as a case

Applies to: `AgentConversationPresentation.Deletion`, `QuestionWizardPresentation.isDismissed`

- A confirmed Delete on the agent conversation screen keeps running while the
  menu, sheets and alerts stay usable. It is tracked as `Deletion` next to
  `modal`.
- `QuestionWizardPresentation.isDismissed` is set once the user confirms
  Dismiss and is never cleared: the host mounts a new wizard for a new question
  set. The pickers stay usable afterwards, so it is tracked next to `modal`.

### 4. A Delete from the agent screen suppresses the `agent:deleted` fallback

Applies to: `Deletion.requested`, `suppressesMissingAgentFallback`, `beginDeletion()`, `deletionFailed()`

`requested` means the `agent.delete` request was sent from this screen and has
not failed. The screen navigates away itself on success, so the
`agent:deleted` fallback must not navigate too. `suppressesMissingAgentFallback`
is true while the Delete is running or has succeeded. When the request fails,
`deletionFailed()` returns to `idle` and the fallback applies again.

### 5. The question wizard reports a dismissal once

Applies to: `QuestionWizardPresentation.confirmDismiss(isSubmitting:isReadOnly:)`

`confirmDismiss` returns true when the caller must report the dismissal: only
once, and not while answers are being submitted or the connection is read-only.

### 6. Create Workspace always closes the switcher

Applies to: `WorkspaceChromePresentation.createWorkspace(canCreate:)`, `dismissWorkspaceCreation()`

Create Workspace always closes the switcher. It opens the sheet only when the
coordinator allows creation; otherwise an open sheet stays.
`dismissWorkspaceCreation()` is called when the coordinator finished or
cancelled creation elsewhere.

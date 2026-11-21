# ADR-0150: Workspace page presentations, archive and delete, and resource actions

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceDetailPresentation` (`Intent/Views/Workspaces/WorkspaceDetailPresentation.swift`), `WorkspaceDetailPresentations`, `WorkspaceActionConfirmations` (`Intent/Views/Workspaces/WorkspaceDetailPresentations.swift`), `WorkspaceDetailView.deleteWorkspace()`, `WorkspaceDetailView.archiveWorkspace()` (`Intent/Views/Workspaces/WorkspaceDetailView+WorkspaceActions.swift`), `WorkspaceResourceActions` (`Intent/Views/Workspaces/WorkspaceResourceActions.swift`), `TerminalRenameAlert` (`Intent/Views/Workspaces/WorkspaceMobileTerminalsView.swift`)

## Context

The workspace page presents confirmations, sheets, full-screen resources,
and the error left by a failed archive or delete over itself.
`WorkspaceDetailPresentation` holds that state.

## Decisions

### 1. A browser made in the creation sheet opens after the sheet dismisses

Applies to: `WorkspaceDetailPresentation.createdBrowser`

The creation sheet stores the new browser in `createdBrowser`. The page opens
it only once the sheet has dismissed.

### 2. The page leaves as soon as the store removes the row

Applies to: `WorkspaceDetailPresentation.perform(_:workspaceId:store:onLeave:)`, `WorkspaceDetailView.performWorkspaceAction(_:)`

Archive and delete go through the workspace store, which removes the row.
The page leaves for the workspace list as soon as the store removes the row,
before the list refresh. When the server does not confirm, the page stays
open and shows the server's message in an alert.

### 3. A terminal error is not shown twice

Applies to: `WorkspaceDetailPresentations`

When the terminal cover dismisses, the page clears the terminal store's error.
The terminal already showed any error inline, so the page does not replay it
as an alert.

### 4. visionOS confirms archive and delete in a focused sheet

Applies to: `WorkspaceActionConfirmations`

These are deliberate confirmation sheets, following the HIG: destructive or
irreversible workspace actions get a focused sheet with one primary action on
visionOS. iPhone and iPad use an alert.

### 5. Workspace resources stay reachable from the overview and from an agent's rail

Applies to: `WorkspaceResourceActions`

The rail creates its `AgentStore` on first use, so it does not load agents for
every screen it appears on.

### 6. An empty terminal name returns to automatic naming

Applies to: `TerminalRenameAlert`

Renaming a terminal to an empty name returns it to automatic naming.

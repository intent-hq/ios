# ADR-1009: Workspace page rows stay flat and do not reread stores

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceAgentListEntry`, `WorkspaceAgentListRow` (`Intent/Views/Workspaces/WorkspaceAgentTreeRow.swift`), `WorkspaceChangesView.commitsSection` (`Intent/Views/Workspaces/WorkspaceChangesView.swift`)

## Context

The workspace page builds its agent list and its commit list as lazy rows,
some through a deferred row provider.

## Decisions

### 1. Padding lives in a lazy body

Applies to: `WorkspaceAgentListEntry`

The entry keeps its padding in a lazy `body`, instead of passing an opaque,
non-Sendable modified view through the deferred row provider.

### 2. One identified layout child per entry

Applies to: `WorkspaceAgentListRow`

Each entry is one identified layout child. This keeps section expansion out of
nested dynamic view lists, whose height estimates can cycle near the scroll
boundary.

### 3. Commit rows capture their values up front

Applies to: `WorkspaceChangesView.commitsSection`

The section reads `store.commits` and the divider once and builds the rows
from those values. The divider overlay must not reread the store when SwiftUI
requests a commit row.

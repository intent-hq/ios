# ADR-0155: Workspace lists snapshot row state before the lazy row provider

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceListSidebar.sidebarRows` (`Intent/Views/Workspaces/WorkspaceListSidebar.swift`), `WorkspaceListView` workspace rows (`Intent/Views/Workspaces/WorkspaceListView.swift`), `WorkspaceDetailView.agentTreeRows` (`Intent/Views/Workspaces/WorkspaceDetailView+AgentGroups.swift`), `WorkspaceScriptsView` (`Intent/Views/Workspaces/WorkspaceScriptsView.swift`)

## Context

SwiftUI can call a `ForEach` row provider asynchronously, outside the main
actor evaluation of the parent body. These lists pass a `@Sendable` row closure.

## Decisions

### 1. Read store state on the main actor, and defer only row bodies

Applies to: all types listed above

Each list builds its rows in the parent body: it snapshots selection, updating
state, store state, launch and connection state, and bindings on the main
actor. Only the row bodies, and the actions they hold, are deferred until the
lazy stack requests them. Nothing reads store state inside SwiftUI's async row
provider.

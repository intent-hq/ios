# ADR-0149: Workspace detail page keeps per-window stores and reloads on switch

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceDetailView` (`Intent/Views/Workspaces/WorkspaceDetailView.swift`), `WorkspaceDetailStores`, `WorkspaceDetailStoresCache` (`Intent/Views/Workspaces/WorkspaceDetailStores.swift`), `WorkspaceDetailView.resetAgentWorkspace(to:)` (`Intent/Views/Workspaces/WorkspaceDetailView+AgentGroups.swift`)

## Context

The workspace page reads agents, notes, and other resources through stores
that sit over the page's session connection. A user moves between workspaces,
opens conversations and comes back, and can lose the connection.

## Decisions

### 1. A window keeps the stores of its last few workspaces

Applies to: `WorkspaceDetailStores`, `WorkspaceDetailStoresCache`, `WorkspaceDetailView.stores`

`WorkspaceDetailStores` are the per-workspace-page stores over the page's
session connection. Each window keeps the stores of its most recently viewed
workspaces in `WorkspaceDetailStoresCache` (`retainedWorkspaceLimit`, 5). A
switch back to a recent workspace, or a connection drop, shows the stores
from memory, so they stay readable during the drop.

### 2. The cache is not observable

Applies to: `WorkspaceDetailStoresCache`

The cache is looked up during view evaluation. That lookup must not invalidate
the view, so the cache is a plain class and not `@Observable`.

### 3. A retained workspace keeps its expanded groups

Applies to: `WorkspaceDetailView.resetAgentWorkspace(to:)`

Only fresh stores reset the agent list view model. A retained workspace keeps
its expanded agent groups.

### 4. Appear, disappear, and workspace change

Applies to: `WorkspaceDetailView.body`

1. On appear, `AgentStore` retains its rows while the user returns from a
   conversation.
2. On a workspace change, `agentStore.startObservingEvents()` is called again
   to register with the new workspace id context.
3. On disappear, `NotificationManager.workspaceClosed` removes only this
   workspace and connection pair, so other windows keep theirs.
4. After the workspace list loads (`workspaceStore.lastUpdated` is set), a
   workspace that is missing from it was deleted or archived elsewhere, and
   the page calls `coordinator.handleMissingWorkspace()`. This does not apply
   while the transfer sheet is open.

### 5. The heading stays mounted while agent rows scroll lazily

Applies to: `WorkspaceDetailView.detailContent`

The heading sits in a plain `VStack` and only the agent rows sit in a
`LazyVStack`. This keeps the focused title field mounted while the agent rows
scroll lazily.

# ADR-0038: Workspace list rows, auto-selection and the persistent sidebar

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceListPresentation`, `WorkspaceListRows` (`Intent/Presentation/WorkspaceListRows.swift`), `IPadWorkspaceAutoSelection` (`Intent/Presentation/IPadWorkspaceAutoSelection.swift`), `WorkspaceSidebarContent`, `WorkspaceSidebarAgents` (`Intent/Presentation/WorkspaceSidebarContent.swift`)

## Context

The workspace list, the iPad auto-selection and the persistent iPad sidebar
must agree on which rows the user sees and on which agent the sidebar shows.

## Decisions

### 1. One row derivation for the list and auto-selection

Applies to: `WorkspaceListRows`, `IPadWorkspaceAutoSelection.workspaceId(in:)`

`WorkspaceListRows` is a pure row derivation shared by the workspace list and
the iPad auto-selection, so "first workspace" always means the top row the
user sees. Groups by repo keep first-seen order, which follows the most recent
member of each group when the input is already sorted. Searching always shows
every group expanded, so matches are never hidden.

### 2. Auto-selection opens the top visible row

Applies to: `IPadWorkspaceAutoSelection`

Wide iPad windows keep a workspace open; compact windows start on the list.
This is the only rule for which workspace, if any, opens when nothing is
selected: the top visible row of the user's list.

### 3. The persistent sidebar shows the open workspace

Applies to: `WorkspaceSidebarContent.resolve(screen:isPersistent:)`

A persistent sidebar shows the open workspace beside its agent or note. The
main view's Back returns both panes to the overview and the list.

### 4. The conversation hides its title only for the agent the sidebar lists

Applies to: `WorkspaceSidebarContent.namesAgent(_:coordinator:)`, `WorkspaceSidebarAgents`, `WorkspaceSidebarAgents.Listing.owner`, `WorkspaceSidebarAgents.namesSelection(isListed:isInitialLoadPending:isRevealPending:)`

The persistent shell sidebar shows the selected agent inside its workspace. A
child agent opened from the transcript is not the sidebar's selection, so it
keeps its own title.

`WorkspaceSidebarAgents` hands the overview's open sections to the sidebar copy
of the workspace (`handoff`) and records which open agent the sidebar actually
lists (`listing`). The conversation hides its title only for that agent.
`Listing.owner` is the sidebar list that reported it: a leaving copy clears
only its own report.

The sidebar names the open agent once its row is listed. While a read that
could list it is in flight, the conversation does not flash a title. A failed
or finished read without the row hands the name back to the conversation.

### 5. Revealing an agent opens its ancestor sections

Applies to: `WorkspaceSidebarAgents.revealGroups(for:lookup:)`

The sections to open so the agent's row appears are the children of each known
ancestor, plus the background section when the chain ends at a background
agent.

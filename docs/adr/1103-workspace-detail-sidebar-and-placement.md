# ADR-1103: Workspace page placement in the iPad shell sidebar and the Duo

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceDetailSidebar`, `WorkspaceSidebarTitleHeader`, `WorkspaceSidebarSelection` (`Intent/Views/Workspaces/WorkspaceDetailSidebar.swift`), `WorkspaceDetailView` placement members (`Intent/Views/Workspaces/WorkspaceDetailView+Placement.swift`), `WorkspaceDetailView.pageContent`, `WorkspaceDetailView.canShare` (`Intent/Views/Workspaces/WorkspaceDetailView+PageChrome.swift`), `WorkspaceDetailView.sidebarContent` (`Intent/Views/Workspaces/WorkspaceDetailView+AgentGroups.swift`), `WorkspaceDetailView.detailContent` (`Intent/Views/Workspaces/WorkspaceDetailView.swift`)

## Context

The workspace page sits in one of three places: a phone page, the iPad
shell's main pane, or the shell's sidebar beside an open agent or note. The
unfolded Duo uses a vertical rail (`usesVerticalBar`) instead of a top bar.

## Decisions

### 1. `WorkspaceDetailSidebar` is chrome for the sidebar copy

Applies to: `WorkspaceDetailSidebar`

It is the chrome for the workspace overview while the overview sits in the
iPad shell's sidebar beside one of its agents or notes. The main view's Back
leaves it.

### 2. The Duo sidebar names itself in the list header's slot

Applies to: `WorkspaceSidebarTitleHeader`, `WorkspaceDetailView.body`, `WorkspaceDetailView.isDuoSidebar`

The Duo sidebar workspace uses the same component, type, and insets as the
"Workspaces" header, fixed above the scrolling page. The Duo header shows no
collapse control, so `ignoreCollapse` is never invoked, and its rail carries
the page actions. The list's header row is as tall as its controls; this one
has none, so the title has a minimum height of
`Constants.WorkspaceSearch.compactHeight`.

### 3. Insets line up with the list

Applies to: `WorkspaceSidebarSelection`, `WorkspaceDetailView.detailContent`

Page children own the 24 pt page inset. On the Duo the page sits on the list's
8 pt inset (`IPadSidebarStyle.compactInset`), so children line up with the
list and the selection fill stops at the column edge.

### 4. Heading spacing

Applies to: `WorkspaceDetailView.iPadHeadingTopSpacing`, `sidebarHeadingTopSpacing`, `duoHeadingTopSpacing`, `usesIPadPaneTitle`

1. Below the iPad pane header, the title's cap top meets the sidebar's filter
   control and the repository line starts at the control's bottom edge.
2. The persistent iPad sidebar already names the workspace above its list
   selection, so the sidebar copy has no extra top spacing.
3. The Duo overview has no header band, so its title's first line sits on the
   sidebar header row, where "Workspaces" is centered.
4. The iPad main pane's title follows the iPad comp; the unfolded Duo keeps its
   rail layout.

### 5. Toolbar placement

Applies to: `WorkspaceDetailView.pageContent`, `WorkspaceDetailView.detailContent`

In the Duo shell the rail carries the page actions, as for conversations. A
system vertical toolbar would add an opaque navigation bar over the top of the
pane. The Duo pane has no top bar for content to fade under, as in
conversations. The standalone page shares its actions menu with the sidebar
copy.

### 6. Sharing

Applies to: `WorkspaceDetailView.canShare`

Owners, and host members who manage every workspace, can share while
connected. The host still refuses anyone it does not allow.

### 7. The sidebar copy keeps the open agent in view

Applies to: `WorkspaceDetailView.sidebarContent`, `adoptOverviewExpansion()`, `revealSidebarAgent()`

The sidebar copy keeps the open agent's row in view, and reports whether it
lists it. An agent opened from elsewhere is found on the Agents tab, so the
tab switches to Agents. The overview's open sections carry over, so the agent
just opened from one stays visible. The reveal opens and loads the sections
above the agent; each loaded parent may reveal its own section, so the reveal
runs up to `revealPasses` (4) passes.

# ADR-0109: iPad shell layout and navigation

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `IPadShellView` (`Intent/App/IPadShellView.swift`), `IPadNavigationState`, `IPadShellLayoutMode`, `IPadFocusPresentation` (`Intent/App/IPadNavigationState.swift`), `AppCoordinator` iPad navigation (`Intent/App/AppCoordinatorIPadNavigation.swift`), `IPadWorkspaceDetailView`, `WorkspaceFirstAgent` (`Intent/App/IPadWorkspaceDetailView.swift`), `AppCoordinator.workspaceListPresentation` (`Intent/App/AppCoordinator.swift`)

## Context

On iPad the app uses its own shell: a rail, a sidebar that is beside the
detail or a drawer over it, and retained panes. The shell routes inside stable
panes instead of pushing and re-pushing navigation stacks.

## Decisions

### 1. Stable panes, no push or re-push

Applies to: `IPadWorkspaceDetailView`, `IPadShellView`

The iPad routes directly within a stable pane. No split-view or
size-class-dependent push or re-push is needed to replace the selected
conversation. The workspace route keeps its identity as tools move its chat
into the sidebar.

### 2. Navigation state belongs to the window

Applies to: `IPadNavigationState`, `IPadNavigationState.isSidebarExpanded`, `IPadFocusPresentation`

`IPadNavigationState` is window-owned presentation state, independent of the
backend and the workspace route. `isSidebarExpanded` is the wide-window choice;
it survives trips through overlay and compact widths. `IPadFocusPresentation`
is explicit input presentation; keyboard notifications never change it.

### 3. Layout modes

Applies to: `IPadShellLayoutMode`, `IPadNavigationState.updateLayout(usesOverlay:usesCompactNavigation:showsWorkspaceList:)`, `IPadShellView.width`

`IPadShellLayoutMode` describes how the shell lays out its sidebar at the
current width. Only overlay widths have a drawer, and nothing is known before
the first measurement.

- `compact`: narrow windows. The drawer fills the width and the rail is hidden.
- `overlay`: the sidebar is a drawer over the detail.
- `split`: the sidebar sits beside the detail and follows `isSidebarExpanded`.
- `unmeasured`: before the first measurement. The sidebar behaves as in `split`.

`IPadShellLayout` reports compact navigation only at overlay widths, so compact
implies overlay in `updateLayout`. Rotation keeps the wide-window preference
without opening a drawer over the conversation in a narrow window: measured
modes start with the drawer closed. `IPadShellView.width` stays nil until
measured, so a zero first width never drives the navigation layout.

### 4. Accessibility and hit-testing order

Applies to: `IPadShellView.shell`, `IPadShellView.navigationRail`

- Retained, hidden sidebar containers must not cover detail controls in the
  accessibility hit-test order, so the sidebar's z-index is -1 when it is not accessible.
- The rail stays above native pane containers' hit regions (z-index 2) in normal navigation.
- Layout changes (first measurement, rotation) must not move VoiceOver focus.
  Focus moves only when the sidebar goes from visible to hidden in the same overlay mode.
- The focus shade is kept outside pane padding so it reaches the full window,
  including the status bar and the shell's outer gutter.

### 5. Visual transitions avoid visible jumps

Applies to: `IPadShellView.pageParallax`, `IPadWorkspaceDetailView.pageTransition(isOverview:)`, `IPadShellView.workspacesSidebar`, `IPadShellView.sidebarShape`

- Pages shift 48 points (`pageParallax`) while they fade, so a slow first frame
  cannot turn into a visible jump. During a swipe the overview shifts toward the
  leading edge and its pages toward the trailing edge; other navigation keeps the plain crossfade.
- The workspaces sidebar swaps between the list and the open agent's or note's
  workspace page. The list stays mounted under a sidebar workspace, keeping its
  scroll position and search. The two swap with a crossfade; nothing moves, so a
  slow first frame cannot read as a jump.
- A drawer sits flush against the undimmed shell, so only its trailing edge is rounded.

### 6. Sidebar content

Applies to: `IPadShellView.workspaceSidebarContent`, `AppCoordinator.showsIPadSidebarWorkspace`, `AppCoordinator.workspaceListPresentation`

- A persistent sidebar beside the detail pane shows the open workspace. Drawers and compact windows keep the list.
- Reselecting Workspaces while the sidebar shows the open workspace leaves it, like the main view's Back.
- `workspaceListPresentation` holds the window's workspace list settings, reported by its iPad sidebar.

### 7. Rail selection never switches backend

Applies to: `AppCoordinator.onSelectIPadSection(_:)`

Selecting a rail destination never switches the window's backend.

### 8. Auto-selection has one trigger

Applies to: `AppCoordinator.iPadAutoSelectedWorkspaceId`, `startObservingIPadAutoSelection()`, `applyIPadAutoSelection()`

The workspace a wide window opens is the top visible row of the user's list.
The observer in `startObservingIPadAutoSelection` is the only auto-selection
trigger; it reruns whenever an input of the decision changes. Production calls
to `applyIPadAutoSelection` come only from that observer.

### 9. Only explicit selections move the shell

Applies to: `AppCoordinator.revealIPadWorkspaceRoute()`

Only explicit workspace selections move the shell. Background redirects (a
missing workspace, a reconnect restore) update the retained pane in place.

### 10. Assistant access is evicted only on a known loss

Applies to: `AppCoordinator.onIPadAssistantAccessChanged()`

Reconnecting keeps the current conversation. Only a known loss of owner access
(`isOwner == false`) evicts the Assistant's privileged presentation.

### 11. Forward swipe opens the top agent

Applies to: `WorkspaceFirstAgent`

`WorkspaceFirstAgent` is the overview's top agent. A forward swipe opens it.

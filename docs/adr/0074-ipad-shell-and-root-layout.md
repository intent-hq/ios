# 0074. iPad shell navigation and root layout

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Wide windows use the iPad shell: a rail, a sidebar and a detail pane. The window width changes with rotation, Split View, Stage Manager and the Surface Duo fold. SwiftUI can render a slow first frame and measures width after the first layout pass.

## Decision

1. **Sections and selection.**
   1. Selecting a rail section never switches the window's backend.
   2. Reselecting Workspaces while the sidebar shows the open workspace leaves it, like the main view's Back.
   3. A wide window auto-opens the top visible row of the user's list (`iPadAutoSelectedWorkspaceId`). The observer in `startObservingIPadAutoSelection()` is the only trigger, and it reruns when any input of the decision changes. When the list is empty, the sidebar is revealed instead.
   4. Only explicit workspace selections move the shell. Background redirects (a missing workspace, a reconnect restore) update the retained pane in place (`revealIPadWorkspaceRoute()`).
   5. Reconnecting keeps the current conversation. Only a known loss of owner access evicts the Assistant's privileged presentation.
   6. Closing a pull request returns the main pane to the workspace and keeps the sidebar.
2. **Layout.**
   1. The width is nil until measured, so a zero first width never drives the layout. Before the first measurement the sidebar behaves as in split mode.
   2. The wide-window sidebar choice (`isSidebarExpanded`) survives trips through overlay and compact widths. Rotation never opens a drawer over the conversation in a narrow window.
   3. Input focus presentation is explicit. Keyboard notifications never change it (`IPadFocusPresentation`).
   4. A persistent sidebar beside the detail can show the open workspace page. Drawers and compact windows keep the list.
   5. The workspace route keeps its identity while tools move its chat into the sidebar.
3. **Motion.** Pages shift by `pageParallax` while they fade, and the list and workspace page crossfade in place. The list stays mounted, so it keeps its scroll position and search. A slow first frame cannot read as a jump.
4. **Accessibility.** Hidden retained sidebar containers sit below the detail in z-order, so they never cover detail controls in hit-testing. Normal navigation stays above native pane hit regions. Layout changes (first measurement, rotation) never move VoiceOver focus.
5. **Root view.**
   1. The launch splash phases and the remote UI switch inside a real container (`ZStack`). `Group` distributes modifiers to both outgoing and incoming content, which briefly gives each its own overlay window.
   2. On the unfolded Surface Duo, the sidebar width is half the window including the system rail and safe-area insets (`duoSidebarWidth`), because the fold divides the full window.

## Consequences

- The shell never jumps or loses VoiceOver focus during resize.
- Code that redirects in the background must not call the explicit selection path.

## Code

- `AppCoordinator`: `onSelectIPadSection(_:)`, `iPadAutoSelectedWorkspaceId`, `startObservingIPadAutoSelection()`, `applyIPadAutoSelection()`, `revealIPadWorkspaceRoute()`, `handleMissingWorkspace()`
- `IPadNavigationState`: `isSidebarExpanded`, `closePullRequestDetail()`, `updateLayout(usesOverlay:usesCompactNavigation:showsWorkspaceList:)`
- `IPadShellLayoutMode`, `IPadFocusPresentation`
- `IPadShellView`: `pageParallax`, `workspaceSidebarContent`, `workspacesSidebar`
- `RootView`: `isLaunchSplash`, `duoSidebarWidth`

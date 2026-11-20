# ADR-1106: Workspace list sidebar styling, selection, and swipe highlights

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceListSidebar` (`Intent/Views/Workspaces/WorkspaceListSidebar.swift`), `WorkspaceListView` (`Intent/Views/Workspaces/WorkspaceListView.swift`), `WorkspaceListGroupHeading` (`Intent/Views/Workspaces/WorkspaceListGroupHeading.swift`), `WorkspaceListContentKind`, `WorkspaceListMenu` (`Intent/Views/Workspaces/WorkspaceListMenu.swift`), `WorkspaceRowView` (`Intent/Views/Workspaces/WorkspaceRowView.swift`), `WorkspaceSwipeRow` (`Intent/Views/Workspaces/WorkspaceSwipeRow.swift`), `SwipeMorphBadge` (`Intent/Views/Workspaces/WorkspaceStatusSwipeBadge.swift`)
- Related issues: ios#339, #745

## Decisions

### 1. The embedded sidebar uses a plain list

Applies to: `WorkspaceListSidebar`

Sidebar list styling clips section edges to the system radius. The persistent
(embedded) sidebar uses the same custom radius for every row, so it uses
`.plain` list style.

### 2. Keyboard and focus

Applies to: `WorkspaceListSidebar`

`scrollDismissesKeyboard` is outside visionOS because SwiftUI marks it
`@available(visionOS, unavailable)`. Custom row backgrounds already mark
selection, so the system keyboard-focus halo is suppressed with
`focusEffectDisabled()` (ios#339).

### 3. Top margin and fade

Applies to: `WorkspaceListSidebar`, `WorkspaceListSidebar.scrollFadeMask`

The filter gap is a scrollable top content margin, so it cannot consume the
reduced viewport above the keyboard; the final row retains bottom clearance.
Rows dissolve under the filter control instead of clipping. The fade fits
inside the list's top margin, so resting rows stay fully opaque.

### 4. Group headers

Applies to: `WorkspaceListSidebar`, `WorkspaceListGroupHeading`

In the embedded sidebar, ordinary header rows avoid the List's implicit
section padding; the scroll-content top margin is the entire filter-to-label
gap. Headers use bottom alignment to keep the label-to-rows gap when the tap
target is taller. The iPhone heading keeps the list's group spacing inside the
tap target. Toggling is disabled while searching, because groups are forced
open. `WorkspaceListGroupHeading.accessibilityIdentifier(for:in:)` is shared
with the iPad sidebar so UI tests address both the same way.

### 5. Row selection and hover

Applies to: `WorkspaceListSidebar.sidebarRow`, `sidebarRowCellInsets`, `listSelectionOpacity(for:)`

The explicit row background replaces the sidebar list's accent-tinted
selection with a neutral grey. On visionOS that custom background also
replaces the system row background that drew the gaze highlight (ios#339), so
the hover effect is reapplied to the row. Hover and selection share one shape
(HIG): on visionOS the row content itself carries the row insets, inside the
highlight, so the highlight covers the whole cell the selection fills, and the
selection stays a persistent fill under it. Swipe rows draw their own
highlight so it moves with the row.

### 6. Who owns the swipe highlight

Applies to: `WorkspaceSwipeRow.selectionOpacity(swipeProgress:)`

The iPad sidebar row owns its highlight. The compact sidebar's list background
owns it at rest and hands it to the moving row as the swipe progresses.

### 7. The swipe badge morphs into a pill

Applies to: `SwipeMorphBadge`

A row's leading icon grows into a labelled pill as the row is swiped right,
naming the action the completed swipe performs.

### 8. The list menu switches lists and takes plain values

Applies to: `WorkspaceListContentKind`, `WorkspaceListMenu`, `WorkspaceListView`

The page's overflow menu (the Intent menu) switches between the workspace and
pull request lists. Native toolbar hosts must not rely on inherited observable
objects (#745), so `WorkspaceListMenu` takes plain values. The page header
reserves the menu's width without inflating the cap-trimmed title height.

### 9. Row PR monitors and visionOS attention

Applies to: `WorkspaceRowView`

Workspace-scoped PR monitors feed the pill pool and the "+N" indicator. They
are read from the window's session, so pinned windows use their own backend,
and fall back to the shared store when no session is in the environment
(previews and tests). Raised attention rows hide while the Intent menu is open
on visionOS. `WorkspaceRowView.BadgeIdentifier` gives the PR badges stable
identifiers, so tests and automation locate them without depending on the
spoken label or layout position.

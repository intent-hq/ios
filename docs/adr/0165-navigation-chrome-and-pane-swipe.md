# ADR-0165: Navigation chrome, workspace subtitle, and pane swipe

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `NavigationPopObserver.Controller` (`Intent/Views/Components/NavigationPopObserver.swift`), `WorkspaceVerticalNavigationToolbar` (`Intent/Views/Components/NavigationBackGesture.swift`), `WorkspaceSubtitleResolver`, `NavigationTitleSubtitleView`, `WorkspaceNavigationSubtitleModifier`, `View.workspaceNavigationSubtitle(title:workspaceId:)` (`Intent/Views/Components/NavigationTitleSubtitleView.swift`), `View.paneSwipe(isSwiping:onBack:onForward:)`, `PaneSwipePolicy`, `PanePan.Coordinator` (`Intent/Views/Components/PaneSwipeGesture.swift`)

## Decisions

### 1. A cancelled interactive pop clears the popping flag

Applies to: `NavigationPopObserver.Controller.viewWillAppear(_:)`

UIKit also calls `viewWillAppear` when an interactive pop is cancelled, so the
controller clears `isPopping` there.

### 2. One vertical toolbar group

Applies to: `WorkspaceVerticalNavigationToolbar`

One vertical group keeps Back above the screen's overflow menu and below the
system status chrome. On the legacy SDK branch, `ToolbarContentBuilder`
requires an expression even when the group has no items, so the branch emits an
empty `ToolbarItemGroup`.

### 3. The workspace subtitle is hidden when there is no title

Applies to: `WorkspaceSubtitleResolver.subtitle(forWorkspaceId:in:)`

The resolver returns nil when the workspace is unknown or its title is blank.
Callers then hide the subtitle entirely; they never show a placeholder.

### 4. Native subtitle on iOS 26+, principal toolbar item elsewhere

Applies to: `WorkspaceNavigationSubtitleModifier`, `NavigationTitleSubtitleView`, `View.workspaceNavigationSubtitle(title:workspaceId:)`

On iOS 26 and later the modifier uses the native `.navigationSubtitle`.
Earlier releases (iOS 18–25) fall back to a `.principal` toolbar item,
`NavigationTitleSubtitleView`, that stacks the navigation title over the
workspace-name subtitle and truncates both. It visually replaces the inline
title. The view's own `.navigationTitle` stays in place on both paths for
back-button labels and accessibility. `title` is the navigation title that the
fallback item re-renders, so it must match the view's `.navigationTitle`.

`.navigationSubtitle` is unavailable on visionOS, so visionOS always uses the
fallback. There the principal item sits leading-aligned next to the back
button, so the two lines are left-aligned to start on the same x.

### 5. Never branch on the subtitle value

Applies to: `WorkspaceNavigationSubtitleModifier.body(content:)`

The iOS 26 path always applies `.navigationSubtitle(subtitle ?? "")`. The
unfolded Duo's vertical-bar trait flips while typing, and swapping branches
would remount the focused composer.

### 6. The modifier fetches workspaces if needed

Applies to: `WorkspaceNavigationSubtitleModifier.fetchWorkspacesIfNeeded()`

On a cold start or deep link the workspace store may not have fetched yet.

### 7. Pane swipe direction and priority

Applies to: `View.paneSwipe(isSwiping:onBack:onForward:)`, `PanePan.Coordinator`

A horizontal page swipe across a navigation pane goes back on a right swipe and
forward on a left swipe. Nested horizontal interactions keep priority: the
navigation stack's interactive edge pop keeps its own edge, and row swipe
actions and sideways-scrolling content inside the pane win. Vertical scrolling
waits until a horizontal page swipe is ruled out. `isSwiping` stays true until
a committed swipe finishes animating, so pages can slide.

### 8. Pane swipe thresholds

Applies to: `PaneSwipePolicy`

- `horizontalDominance`: horizontal speed must exceed vertical speed by this
  factor before the pane claims a drag.
- `horizontalScrollTolerance`: content wider than its viewport by more than
  rounding counts as sideways scrolling.
- `resistedOffset(for:)`: the pane only hints at the drag; the destination
  replaces it once the swipe commits.
- `outcome(translation:velocity:)`: a fast flick commits in its own direction;
  a slow drag needs distance and must not be reversing.

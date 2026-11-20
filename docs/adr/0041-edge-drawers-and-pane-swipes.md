# 0041. Edge drawers and pane swipes

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The app has two edge drawers (Connections on the left, agent history on the right) and a horizontal page swipe across navigation panes. These gestures share the screen with navigation edge pops, row swipe actions and sideways-scrolling content.

## Decision

1. **Drawer layout.**
   1. `EdgeDrawer` slides the page away from one physical screen edge. Offsets are physical, so the panel stays on its physical side in both layout directions.
   2. A closed drawer removes its panel from the view tree. Ancestor visibility modifiers can expose hidden descendants, so a closed panel must not leave connection or agent rows in the accessibility tree.
   3. The page is hidden from accessibility only while the drawer is revealed, with `accessibilityHidden(true, isEnabled:)`. Do not write `accessibilityHidden(false)`: a closed drawer must keep the hidden states inside the page.
2. **Drawer gesture.**
   1. Each drawer pan uses its own recognizer class (`EdgeDrawerPanRecognizer`), so nested drawers never wait on each other.
   2. Row actions and scrolling wait until the drawer's direction and edge gate rejects the pan.
   3. The coordinator reads `isOpen` as a live binding. UIKit can ask the gesture to begin before SwiftUI refreshes the representable.
3. **Pane swipe.**
   1. A swipe right goes back and a swipe left goes forward. The pane only hints at the drag; the destination replaces it after commit.
   2. `isSwiping` stays true until a committed swipe finishes its animation, so pages can slide.
   3. A fast flick commits in its own direction. A slow drag must pass the commit distance and must not be reversing.
   4. Precedence: the navigation stack's edge pop, row swipe actions and sideways-scrolling content inside the pane win. Vertical scrolling waits until a horizontal swipe is ruled out.
4. **Navigation pop.** UIKit also calls the pop transition callback when an interactive pop is cancelled. `NavigationPopObserver` clears `isPopping` in both cases.

## Consequences

- A new horizontal gesture inside a pane or drawer must declare its precedence against these recognizers.

## Code

- `EdgeDrawer`: `panelAlignment`, `isRevealed`
- `EdgeDrawerGesture`, `EdgeDrawerPanRecognizer`, `EdgeDrawerDrag`
- `PaneSwipePolicy`: `outcome(translation:velocity:)`, `resistedOffset(for:)`, `horizontalDominance`
- `NavigationPopObserver`

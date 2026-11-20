# ADR-1205: Edge drawer layout, gestures, and accessibility

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `EdgeDrawer` (`Intent/Views/Components/EdgeDrawer.swift`), `EdgeDrawerGesture`, `EdgeDrawerPanRecognizer`, `EdgeDrawerPan.Coordinator` (`Intent/Views/Components/EdgeDrawerGesture.swift`)

## Context

`EdgeDrawer` reveals a panel by sliding the page away from one physical screen
edge. The Connections switcher (left) and the agent history (right) share it.
The drag math is in `EdgeDrawerDrag` (`Intent/Presentation/EdgeDrawerDrag.swift`).

## Decisions

### 1. The panel pins to its physical side

Applies to: `EdgeDrawer.panelAlignment`

Offsets are physical, so the panel pins to its physical side in both layout
directions.

### 2. A closed panel is removed, not hidden

Applies to: `EdgeDrawer.body`

Ancestor visibility modifiers can expose hidden descendants. A closed panel must
not leave connection or agent rows in the accessibility tree, so the panel is
only in the hierarchy while it is revealed.

### 3. A closed drawer preserves hidden states in the page

Applies to: `EdgeDrawer.slidingPage`

The page uses `accessibilityHidden(true, isEnabled: isRevealed)` so a closed
drawer keeps the hidden states inside the page.

### 4. The gesture reports pans in the drawer's opening frame

Applies to: `EdgeDrawerGesture`

Translations and velocities are converted with `EdgeDrawerDrag.towardOpening`
before they are reported.

### 5. Drawer pans have their own recognizer class

Applies to: `EdgeDrawerPanRecognizer`, `EdgeDrawerPan.Coordinator.gestureRecognizer(_:shouldBeRequiredToFailBy:)`

The subclass distinguishes drawer pans so nested drawers never wait on each
other. Other pan recognizers (row actions and scrolling) wait for the
direction and edge gate to reject the drawer pan.

### 6. The coordinator reads the live open state

Applies to: `EdgeDrawerPan.Coordinator.isOpen`

UIKit can ask `gestureRecognizerShouldBegin` before SwiftUI refreshes the
representable, so the coordinator holds the binding and reads the live state.

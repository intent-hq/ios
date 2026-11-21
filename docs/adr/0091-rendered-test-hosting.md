# 0091. Rendered unit-test hosting

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

Some unit tests render UIKit or SwiftUI views in a real window to check appearance and visibility callbacks. The test host shares one app process and one scene across suites.

## Decision

1. Drive appearance from the window (`overrideUserInterfaceStyle`), as the app's root `preferredColorScheme` does. On iOS 18 a view's own `traitOverrides` do not propagate in a hidden window.
2. A test window is visible but never key. Other suites rely on the host window keeping key status.
3. Visibility tests use a foreground window and the real `onScrollVisibilityChange` callbacks. `onAppear` on a prefetched lazy row is not enough, because it fires for rows that are not on screen.
4. To change Dynamic Type, set the window's `traitOverrides` so UIKit applies inherited traits synchronously. Layout alone does not flush traits on a detached view. The test then checks that the production trait observer refreshed the font; it never calls the font helper itself.
5. Focus-order tests use a responder spy, not a key window, so queue order is deterministic. Real keyboard entry is covered by UI tests.
6. A closed window's SwiftUI graph is released on a later run-loop turn. A teardown test keeps the coordinator alive until a bounded deadline passes.

7. **Painted geometry** (`CreationPickerRenderedGeometry`). Layout tests that must prove a control is visible measure painted pixels, not accessibility rectangles: a CGRect-only fixture cannot detect a broken capture or coordinate conversion.
   1. Capture at scale 1, so image pixels and window-local points share coordinates. Convert frames only after the painted fixture has settled, and keep local, window-pixel and screen coordinates apart.
   2. A region that touches the canvas edge fails closed (`ObservationError.missingOrAmbiguousRegion`): a clipped bitmap cannot show the missing part. Tiny anti-aliased islands are ignored by area, never by dimension, so a 120×1 clipping strip still reaches the assertions.
   3. Compare each edge within one pixel, because the 1x capture can blend an interior edge; checking only the size would miss a flipped or offset image.
   4. Wait for stability over a minimum number of samples, even past the deadline, because SwiftUI can finish Dynamic Type reflow after the host appears and capture can be slow.
   5. The host canvas is tall enough to keep every measured row mounted at accessibility sizes. A readable-size floor detects clipping; it does not claim to measure the full hit target.

## Consequences

- Rendered badge tests are gated, not skipped silently: the simulator lane always turns accessibility on (`scripts/xcodebuild.sh`), so `SyntheticBadgeHost.publishesAccessibilityTree()` is consulted only on a physical device, and a simulator regression fails a badge test (from test comments).
- A test that calls `makeKeyAndVisible()` can break unrelated suites.
- Unit-test runners do not start XCTest's UI automation session, and simulator preferences alone do not turn on SwiftUI's in-process accessibility tree. `SyntheticBadgeAccessibilityRuntime` turns it on with the same runtime entry points as AccessibilitySnapshot's `ASAccessibilityEnabler`. It lives only in the test bundle and is never linked into the app (from test comments).

## Code

- `AgentAvatarPulseTests`, `AgentWaitingViewTests`, `ComposerSubmitPolicyTests`, `ComposerFocusBindingTests`, `ConnectionLossPresenterTests`, `CreationPickerControlsTests`, `CreationPickerRenderedGeometry`

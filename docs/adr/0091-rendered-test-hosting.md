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

## Consequences

- A test that calls `makeKeyAndVisible()` can break unrelated suites.

## Code

- `AgentAvatarPulseTests`, `AgentWaitingViewTests`, `ComposerSubmitPolicyTests`, `ComposerFocusBindingTests`, `ConnectionLossPresenterTests`

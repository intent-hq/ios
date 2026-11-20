# 0046. Connection-loss windows, the read-only pill and read-only controls

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

ADR 0071 and ADR 0113 decide when the blocking "Can't reconnect" screen and the read-only banner show. This record covers how they are presented and how controls behave while the Mac connection is lost.

## Decision

1. **Separate windows in the same scene.**
   1. A root overlay sits below sheets and full-screen covers. So `ConnectionLossPresenter` and `ReadOnlyBannerPresenter` each host their surface in a separate window of the same scene. It covers presentations without dismissing them or losing drafts.
   2. Visibility is set synchronously, outside SwiftUI's transitions.
   3. Window levels: the blocking screen is `.alert + 1`. The read-only banner is `.alert - 1`, below the blocking screen and above every presentation.
   4. An initial update can come before `didMoveToWindow`, and UIKit or SwiftUI can remove the anchor during scene transitions. A missing window is not a request to dismiss. The source stays until a real rebind, recovery, Home, or `dismantleUIView` tears it down.
   5. SwiftUI owns the presenter's coordinator while it is mounted. The hosted content must not hold the coordinator strongly.
2. **Blocking screen.**
   1. It shows only when reconnection stopped for good (revoked access, a different person, an incompatible host). Ordinary drops use the banner.
   2. Before it shows, it freezes a snapshot of the source window, including presented sheets, as its backdrop. It does not use a material, which would add a second tint and flatten the frosted design. The snapshot is one point per pixel, kept in memory only, and released on every hide.
   3. The screen always renders dark. It overrides both the copied source environment and the window appearance. The source page can be light.
   4. Only the backdrop ignores safe areas. Content and the action scroll together when large text or certificate warnings need more height. The artwork balances around the full window centre, not the safe-area centre.
3. **Read-only pill.**
   1. The banner window never snapshots, disables or hides the app. It takes touches only inside the banner's reported frame (`PassthroughWindow`). The window never becomes key, so a focused composer keeps its keyboard.
   2. The collapsed pill floats at the bottom without reserving space, so nothing moves when the connection drops or returns. Tapping it opens a card with guidance, certificate warnings, Retry and Back to Home.
   3. The pill floats above bottom chrome that reports itself with `keepsReadOnlyPillAbove(isActive:)` (composers, search, floating buttons), within the window's lower half, and skips chrome hidden under a sheet or cover. On iPad it centres on the panel marked with `centersReadOnlyPill()`, unless a sheet or cover is above it.
   4. The banner copy follows `ConnectionNetworkMessage`, so a phone-side problem names its fix instead of blaming the Mac. Network evidence only changes copy; it never decides whether the remote UI is blocked.
4. **Read-only controls.**
   1. `isRemoteReadOnly` is set per window by `RootView`. Sheets and covers inherit it.
   2. `requiresLiveConnection(_:)` disables a control that sends a change to the Mac, and catches taps on the disabled control to explain why. It adds to permission checks and never replaces them.
   3. In menus, toolbars and swipe actions, where a tap hint cannot attach, use `disabledWhileReadOnly()`.
   4. A screen that failed during a drop reloads with `onReconnect(_:)`.

## Code

- `ConnectionLossPresenter`: `Coordinator`, `WindowAnchor`, `HideReason`
- `ReadOnlyBannerPresenter`: `PassthroughWindow`, `Coordinator`
- `ConnectionLossOverlay`, `ConnectionLossLayers`, `ReadOnlyBanner`, `ReadOnlyBannerMessage`, `ConnectionNetworkMessage`
- `ReadOnlyPillClearance`: `anchor(coverage:)`, `top(under:windowBottom:coverage:)`; `keepsReadOnlyPillAbove(isActive:)`, `centersReadOnlyPill()`
- `isRemoteReadOnly`, `requiresLiveConnection(_:)`, `disabledWhileReadOnly()`, `onReconnect(_:)`

# ADR-0172: Read-only banner and pill clearance

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ReadOnlyBannerPresenter` (`Intent/Views/Connection/ReadOnlyBannerPresenter.swift`), `ReadOnlyBanner`, `ReadOnlyBannerMessage`, `WidthCap` (`Intent/Views/Connection/ReadOnlyBanner.swift`), `ReadOnlyPillClearance` (`Intent/Views/Connection/ReadOnlyPillClearance.swift`), `ConnectionNetworkMessage` (`Intent/Views/Connection/ConnectionNetworkMessage.swift`), `ConnectionNetworkStatusView` (`Intent/Views/Connection/ConnectionNetworkStatusView.swift`)

## Context

`ReadOnlyBanner` is a floating, non-blocking pill shown while reconnection
keeps trying. It sits at the bottom of the window, above any composer or
floating button reported to `ReadOnlyPillClearance`, without reserving space.
Tapping it opens a card with guidance, certificate warnings, Retry, and Back to
Home.

## Decisions

### 1. The banner lives in a pass-through window of the same scene

Applies to: `ReadOnlyBannerPresenter`, `ReadOnlyBannerPresenter.PassthroughWindow`, `ReadOnlyBanner.onInteractiveFrameChange`

Like `ConnectionLossPresenter`, the presenter hosts the banner in a separate
window of the same scene, so it stays above sheets and full-screen covers.
Unlike the blocking overlay, it never snapshots, disables, or hides the app. The
banner reports its frame in window coordinates, and the window takes touches
only inside that frame; all other touches pass through to the app. The window
never becomes key, even when touched, so the app's first responder (a focused
composer) keeps its keyboard. The window level is `.alert - 1`: below the
blocking overlay (`.alert + 1`) and above every presentation. The collapsed
pill floats over the app without reserving space, so nothing below it moves
when the connection drops or comes back.

### 2. Copy follows `ConnectionNetworkMessage`

Applies to: `ReadOnlyBannerMessage`, `ConnectionNetworkMessage`, `ConnectionNetworkStatusView`

The banner copy follows `ConnectionNetworkMessage`, so a phone-side problem
names its fix instead of blaming the Mac. `ConnectionNetworkMessage` is copy
only: general-path network evidence never decides whether remote UI is
blocked. `ConnectionNetworkStatusView` is the shared passive text for eligible
loss surfaces and inline startup and failure surfaces.

`startupState` is the desktop's startup phase while it is still starting up
(R1.7). `title` is the full sentence for the expanded card and VoiceOver.
`shortTitle` is a few words for the collapsed pill.

### 3. Pill placement

Applies to: `ReadOnlyBanner`, `ReadOnlyPillClearance`

`ReadOnlyPillClearance` records the bottom chrome in one window (composers,
search, floating buttons) that the pill floats above instead of covering.
Frames are in window coordinates, which the pill's same-size window shares.

- `top(under:windowBottom:coverage:)` returns the top of the highest chrome
  under the pill's span within the window's lower half, skipping chrome hidden
  beneath a sheet or cover.
- `anchor(coverage:)` returns the content panel to centre on, unless a sheet
  or cover sits above it. `centersReadOnlyPill()` reports that panel; the iPad
  shell is the layout that has one.
- A reporter measures nil while inactive, so activation itself reports the
  frame.
- `ReadOnlyBanner.safeArea` is in window coordinates; it ends above the home
  indicator and the keyboard.
- `Layout.bottomGap` is the space between the pill and the safe area or the
  chrome below it.

### 4. Pill shape and size

Applies to: `ReadOnlyBanner.Layout.capsuleCornerRadius`, `WidthCap`, `ReadOnlyBanner.content`

`capsuleCornerRadius` is larger than half the pill's height; the shape clamps
it into a capsule. `WidthCap` caps the proposed width but, unlike
`frame(maxWidth:)`, takes its content's size, so the collapsed pill hugs short
text and truncates long text. Large type can outgrow the screen, so the expanded
details scroll.

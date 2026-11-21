# ADR-0182: Splash art and loading indicator playback

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `SplashArtView`, `SplashFrameView` (`Intent/Views/Onboarding/Splash/SplashArtView.swift`), `IntentLoadingIndicator` (`Intent/Views/Components/IntentLoadingIndicator.swift`)
- Related issues: ios#256, ios#475

## Decisions

### 1. The splash plays the supplied twist intro and pulse loop

Applies to: `SplashArtView`

`SplashArtView` is the full-screen launch splash. It uses the supplied twist
intro and pulse loop.

### 2. Decoded compositions live only as long as the view

Applies to: `SplashArtView.lease`

The animation lease is held for the view's lifetime only, so the decoded
compositions go away with the splash (ios#256).

### 3. One clock drives playback

Applies to: `SplashFrameView`

Lottie renders the source paths, keyframes, and time remapping directly. The
existing monotonic clock is the only playback driver: Lottie never starts an
independent animation that could continue while the scene is inactive. The
frame honors the SwiftUI size proposal instead of the 256-point intrinsic size
(ios#475).

### 4. Loader rest positions

Applies to: `IntentLoadingIndicator.body`

The twist-then-pulse mode keeps the existing intro's paused position. Looping
loaders rest on the complete mark.

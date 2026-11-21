# ADR-0040: Launch timelines stop on cancellation, and splash animations are leased

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `LaunchPhaseTimeline` (`Intent/Presentation/LaunchPhaseTimeline.swift`), `SplashAnimation`, `SplashAnimationStore` (`Intent/Presentation/SplashAnimation.swift`), `SplashPlaybackClock`, `SplashPlaybackState` (`Intent/Presentation/SplashPlaybackState.swift`)
- Related issues: ios#230, ios#247, ios#256

## Decisions

### 1. Launch delays throw on cancellation

Applies to: `LaunchPhaseTimeline`

`LaunchPhaseTimeline` holds the staged delays behind the launch screens'
timelines: the intro beat of `LoadingView` and the workspace-data poll of
`ConnectingView`. Both helpers throw `CancellationError` as soon as the owning
task is cancelled. A dismissed or superseded screen therefore stops advancing
its timeline and never reaches the coordinator callback after the delay
(ios#230).

`delay(for:)` propagates cancellation instead of swallowing it. A cancellation
that lands after the sleep completed but before the caller resumes is surfaced
too, so a completed beat never advances a task that was cancelled meanwhile.

`poll(until:timeout:interval:)` checks `condition` every `interval` until it
holds or `timeout` elapses on the monotonic `ContinuousClock`. It returns
whether the condition held before the deadline. When the task is cancelled it
throws `CancellationError` without evaluating `condition` again.

### 2. Splash compositions bypass Lottie's cache and are leased

Applies to: `SplashAnimation.init?(bundle:)`, `SplashAnimationStore`, `SplashAnimationLease`

The compositions are decoded without Lottie's process-wide cache
(`animationCache: nil`), so their lifetime stays bounded by the lease of the
visible splash (ios#256). Concurrent owners share one decode, and the
compositions are released with the last lease instead of living for the whole
process.

### 3. Playback uses each composition's own timing

Applies to: `SplashAnimation.frame(at:animated:mode:)`

The selected sequence plays using the timing of each JSON. The first frame of
pulse is a complete mark; the first frame of twist is empty. `twistLoop`
skips the empty opening frame without changing the duration of the
composition.

### 4. Splash time is monotonic and excludes pauses

Applies to: `SplashPlaybackClock`, `MediaTimeSplashClock`, `SplashPlaybackState`

The clock is monotonic (ios#247). It is injectable so tests step time
deterministically. Production samples `CACurrentMediaTime`, which wall-clock
(NTP) adjustments never move. `SplashPlaybackState` keeps the playback
position on that one clock and excludes time spent paused.

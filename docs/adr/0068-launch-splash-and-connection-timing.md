# 0068. Launch, splash and connection status timing

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Launch screens advance on timers, the splash plays Lottie compositions, and the conversation shows staged connection progress.

## Decision

1. **Launch timeline (ios#230).** `LaunchPhaseTimeline` throws `CancellationError` as soon as its task is cancelled, so a dismissed screen never reaches the coordinator callback after a delay. Cancellation that lands after the sleep but before the caller resumes is surfaced too. Polling uses the monotonic `ContinuousClock` and does not evaluate the condition again after cancellation.
2. **Splash memory (ios#256).** Compositions decode without Lottie's process-wide cache. Concurrent owners share one decode through `SplashAnimationStore`, and the last `SplashAnimationLease` releases it.
3. **Splash playback (ios#247).** Playback uses one monotonic clock (`CACurrentMediaTime`), which NTP adjustments never move, and excludes paused time. Each JSON keeps its own timing. Twist's empty first frame is skipped without changing the duration.
4. **Connection status.** A phase is a transcript stage or a daemon startup phase. Progress resets only the idle clock; elapsed time always uses the conversation's start. A new input hides the delayed state at once, before SwiftUI delivers `onChange`.

## Code

- `LaunchPhaseTimeline`: `delay(for:)`
- `SplashAnimation`: `frame`, `SplashAnimationLease`, `SplashAnimationStore`: `lease`
- `SplashPlaybackClock`, `MediaTimeSplashClock`, `SplashPlaybackState`
- `ConversationConnectionStatusTiming`: `update`, `elapsed`, `isDelayed`, `ConversationConnectionStep`

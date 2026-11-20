# 0044. visionOS window feedback sounds

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

On visionOS, each workspace window can play a notification sound: the agent-completion chime and the workspace attention cue. With headphones, spatial audio lets the user hear which window asked for attention. Duplicate windows bound to the same backend (the rebound-window quirk) observe the same `FeedbackEvent` or `WindowCueEvent`.

## Decision

1. **Play from the window.** `WindowFeedbackSoundEmitter` is an invisible RealityKit anchor in the window's scene. A window mounts one emitter per sound source. Only the window that must play gets a non-nil `eventID`, and each fresh id plays again, also for back-to-back alerts.
2. **One playback per event.** `WindowSoundClaimRegistry` deduplicates playback. The first emitter that observes an event id claims it and plays. Later observers of the same id skip. Windows on different backends see different ids and are not affected. The registry remembers the last 32 ids (FIFO); events are claimed within one main-actor turn of publication. The registry is platform-neutral so the iOS test target can test it; only visionOS emitters use it.
3. **Anchor the audio to the scene.**
   1. The emitter reads its window's scene identifier (`UIScene.session.persistentIdentifier`) when it moves into a window. It reports the id asynchronously, because `didMoveToWindow` can run inside a SwiftUI update pass, where `@State` must not change.
   2. Before each playback, the emitter anchors the audio session's intended spatial experience to this scene, so audio before visionOS 26 localizes to this window and not to the app's first window.
   3. The emitter anchors after the resource load and immediately before `playAudio`. The first play suspends on the load, and another window's first play can re-anchor the shared session in between.
   4. Anchoring is best effort. A failure or an unresolved scene id does not stop playback.

## Code

- `WindowSoundClaimRegistry`: `shared`, `claim(_:)`, `init(capacity:)`
- `WindowFeedbackSoundEmitter`: `eventID`, `play()`, `anchorAudioToThisScene()`
- `WindowSceneIdentifierReader`

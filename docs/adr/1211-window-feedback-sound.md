# ADR-1211: Window feedback sound on visionOS

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WindowSoundClaimRegistry`, `WindowFeedbackSoundEmitter`, `WindowSceneIdentifierReader` (`Intent/Views/Components/WindowFeedbackSoundEmitter.swift`)

## Context

On visionOS, notification sounds play from the window that asked for attention.

## Decisions

### 1. The sound plays from this window's scene

Applies to: `WindowFeedbackSoundEmitter`

An invisible RealityKit anchor plays the notification sound from within this
window's scene, so visionOS spatial audio localizes the sound to the window.
With headphones the user hears which workspace window asked for attention. A
window mounts one emitter per sound source (the agent-completion chime and the
workspace attention cue). Only the window that must emit receives a non-nil
`eventID`, and each fresh id re-triggers playback, even for back-to-back
alerts. `eventID` is nil when the window has nothing to play. When duplicate
windows share a backend and observe the same event, `WindowSoundClaimRegistry`
lets exactly one of them play it.

### 2. The registry is platform-neutral

Applies to: `WindowSoundClaimRegistry`

The registry is not behind `#if os(visionOS)` so the iOS test target can
exercise it. Only visionOS emitters consult it.

### 3. Claim contract and capacity

Applies to: `WindowSoundClaimRegistry.claim(_:)`, `WindowSoundClaimRegistry.init(capacity:)`

`claim(_:)` returns true when the id was unclaimed (the caller plays) and false
when another window's emitter already claimed it (the caller skips).
`capacity` bounds the remembered ids with FIFO eviction. Events are claimed
within one MainActor turn of publication, so a small window (32) is enough.

### 4. Audio is anchored to this scene, right before playback

Applies to: `WindowFeedbackSoundEmitter.sceneID`, `WindowFeedbackSoundEmitter.play()`

`sceneID` is this window's scene identifier, captured from the hosting
`UIWindow`. Before each playback the audio session's intended spatial experience
is anchored to this scene, so pre-visionOS-26 spatial audio localizes the sound
to this window rather than the app's first window.

Anchoring happens right before playback. The first play suspends on the
resource load, and an interleaved first play from another window could
re-anchor the shared audio session in between. Anchoring after the load keeps
this window's anchor in effect when its sound starts.

Anchoring is best effort. A failed anchor or an unresolved scene id does not
stop playback.

### 5. The scene identifier is reported asynchronously

Applies to: `WindowSceneIdentifierReader`

The reader reports `UIScene.session.persistentIdentifier` once the view lands
in a window. The report is deferred to the next main-queue turn, because
`didMoveToWindow` can fire inside a SwiftUI update pass, where mutating
`@State` is not allowed.

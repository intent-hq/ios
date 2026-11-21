# 0026. Audio session and dictation

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Video playback, dictation recording and short chimes share one process-wide `AVAudioSession`, including across visionOS windows.

## Decision

1. **One owner with leases.** `MediaAudioSession` is an actor that holds leases per purpose. A dismissed player's delayed cleanup cannot disable a new recording or another player. No suspension occurs while the system session changes.
2. **Client boundary.** The synchronous system calls sit behind `MediaAudioSessionClient`, so the owner serializes them off the main actor, independent of players and audio engines.
3. **Categories.** A recording in another window must not silence video or lose microphone access; dictation returns to its own category afterwards. A short chime uses `.ambient` with `.mixWithOthers` and respects the silent switch. Callers configure only while a lease is held.
4. **Failure.** If activation partly succeeded, release restores the other consumers, or returns audio to other apps when it was the only one.
5. **Dictation (`SpeechDictationController`, visionOS).** Microphone audio streams through `AVAudioEngine` into `SFSpeechRecognizer` (on-device when supported).
   1. Closures given to AVFoundation and Speech run off the main queue and are `@Sendable`, never main-actor-inferred; they hop back with Sendable values only. The input tap runs on the realtime thread; Speech requires `append(_:)` there, so the request is captured `nonisolated(unsafe)`. The authorization callback runs on an arbitrary queue.
   2. **Start window.** `startRecording()` enters `starting` synchronously before the first await. `DictationStartState` gives each start a token; after each await the start continues only while its token is current. A stop during the window (second tap, view gone, scene inactive, send) cancels it, so `begin` never runs. The mic shows active from the tap on, so a second tap cancels a pending start. `startRecording()` has activated the shared session's recording category before the engine starts, even after video playback.
   3. **Stop.** `DictationStopReason.acceptsFinalResult`: deliberate endings keep the more accurate final result; interruptions must not resurrect text. An outside edit wins over a late final. `DictationStopAction` is the decision table: after a graceful stop, an interrupting stop (for example `send`) still severs the callback and cancels the lingering task.
   4. **Segments.** The recognizer's transcript is cumulative only within an utterance. A silence pause ends it with `isFinal` or a result with `speechRecognitionMetadata`. That segment is committed, and `restartSegment()` installs a fresh recognition task so one tap survives pauses. `segmentGeneration` advances on every install, so a superseded task's late final or error cannot leak text or stop recognition. A stop does not advance it, so a graceful stop's final still arrives. After a metadata result the old task is cancelled so its later final is stale. If a new segment cannot start, the session stops as recognizer-finished.
   5. **Merging.** `DictationTranscript` captures text and caret at start and replaces the previous partial at that point, in UTF-16 offsets (`UITextView.selectedRange`), with single-space separation. A nil caret (restored draft) inserts at the end. `DictationSession` applies a transcription only while the composer text is exactly the last merge; otherwise it reports `.diverged` and the caller stops dictation. The model applies repeated transcriptions, because the controller already delivers at most one segment end per segment; a phrase dictated twice appears twice.

## Code

- `SpeechDictationController`: `startRecording()`, `stop(reason:)`, `installRecognition(on:with:)`, `restartSegment()`, `segmentGeneration`, `onTranscriptChange`; `DictationStartState`, `DictationStopReason`, `DictationStopAction`, `DictationTranscript`, `DictationSession`
- `MediaAudioSession`: `acquire(_:)`, `release(_:)`, `configure()`, `updateAfterRelease()`, `Purpose`; `MediaAudioSessionClient`

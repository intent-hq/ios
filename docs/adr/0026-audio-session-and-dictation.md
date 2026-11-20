# 0026. Audio session and dictation

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Video playback, dictation recording and short chimes share one process-wide `AVAudioSession`, including across visionOS windows.

## Decision

1. **One owner with leases.** `MediaAudioSession` is an actor that holds leases per purpose. A dismissed player's delayed cleanup cannot disable a new recording or another player. No suspension occurs while the system session changes.
2. **Client boundary.** The synchronous system calls sit behind `MediaAudioSessionClient`, so the owner serializes them off the main actor, independent of players and audio engines.
3. **Categories.** A recording in another window must not silence video or lose microphone access; dictation returns to its own category afterwards. A short chime uses `.ambient` with `.mixWithOthers` and respects the silent switch. Callers configure only while a lease is held.
4. **Failure.** If activation partly succeeded, release restores the other consumers, or returns audio to other apps when it was the only one.

## Code

- `MediaAudioSession`: `acquire(_:)`, `release(_:)`, `configure()`, `updateAfterRelease()`, `Purpose`; `MediaAudioSessionClient`

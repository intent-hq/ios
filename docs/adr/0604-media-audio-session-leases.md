# ADR-0604: MediaAudioSession owns the process-wide audio session through leases

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `MediaAudioSession`, `MediaAudioSessionClient` (`Intent/Services/MediaAudioSession.swift`)

## Context

`AVAudioSession` is process-wide, including across visionOS windows. Players,
dictation, and notification chimes all need it.

## Decisions

### 1. System calls sit behind `MediaAudioSessionClient`

Applies to: `MediaAudioSessionClient`

The synchronous system calls live behind this protocol so the session owner can
serialize them off the MainActor, independently of players and audio engines.

### 2. Leases decide the session state

Applies to: `MediaAudioSession.acquire(_:)`, `MediaAudioSession.release(_:)`

Leases prevent a dismissed player's delayed cleanup from disabling a new
recording or another player. No suspension occurs while the actor changes the
system session.

### 3. A failed acquire restores the other consumers

Applies to: `MediaAudioSession.acquire(_:)`

Activation may have partially succeeded. On failure the lease is dropped and
the session is updated as after a release: other consumers are restored, or
audio returns to other apps when this was the only lease.

### 4. Category per purpose

Applies to: `MediaAudioSession.configure()`

1. Dictation wins. A recording in another window must not silence video or lose
   microphone access, so dictation with playback uses `.playAndRecord`. When
   playback ends, the session returns to dictation's own category.
2. A notification chime uses `.ambient` with `.mixWithOthers`: it mixes with
   other apps' audio and respects the silent switch.
3. Callers configure only while at least one lease is held, so one of the
   purposes always applies.
4. Deactivating `AVAudioSession` does not reset its category. Each consumer
   sets its own category before activation, also after a different use.

# ADR-0618: visionOS live dictation with segment-aware merging

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DictationStopReason`, `DictationPhase`, `DictationStartState`, `DictationStopAction`, `DictationTranscript`, `DictationSession`, `SpeechDictationController` (`Intent/Services/SpeechDictationController.swift`)

## Context

`SpeechDictationController` is visionOS-only live dictation. It streams
microphone audio through `AVAudioEngine` into `SFSpeechRecognizer` (on-device
when supported) and delivers partial and final transcriptions through
callbacks. The pure types around it are extracted so the races are
unit-testable without Speech.

## Decisions

### 1. The stop reason decides whether a late final result applies

Applies to: `DictationStopReason`, `DictationStopReason.acceptsFinalResult`

The stop reason decides whether a final recognition result that arrives after
the stop is still applied. Deliberate endings keep the (usually more accurate)
final result. Interruptions must not bring text back.

1. `recognizerFinished`: the recognizer delivered a final result on its own,
   for example after silence. Accepts the final.
2. `userTapped`: the user tapped the mic button to end dictation. Accepts the
   final.
3. `sceneInactive`: the scene became inactive (the user looked away, or the app
   went to the background).
4. `send`: the message was sent, and the composer text was consumed.
5. `textEdited`: the composer text was edited outside dictation (typed, or
   replaced by the view model). The edit wins, and a late final must not
   clobber it.

### 2. The start window can be cancelled

Applies to: `DictationPhase`, `DictationStartState`, `SpeechDictationController.startRecording()`

1. `DictationPhase.starting` covers the window between the mic tap and the
   audio engine actually running, while `startRecording()` awaits the
   permission prompts.
2. A stop during that window (second tap, view disappeared, scene inactive,
   send) must cancel the pending start so `begin` never runs.
3. Each start carries a generation token. It may proceed past an await only
   while the state is still starting that same attempt. A cancel followed by a
   fresh start invalidates the older pending attempt.
4. `requestStart()` moves idle to starting and returns the token. It returns
   nil when a session is already starting or recording. `abort(_:)` is for a
   failed attempt (permission denied, engine error).
5. `startRecording()` enters the starting phase synchronously before the first
   await. It sets `unavailabilityHint` instead of throwing when dictation
   cannot start.

### 3. Stop decision table

Applies to: `DictationStopAction`, `SpeechDictationController.stop(reason:)`

After a graceful stop (`userTapped`) the session is no longer recording, but
the recognizer may still deliver its final result. A stop in that window whose
reason rejects final results (for example `send`) must still sever the
transcript callback, so the late final cannot bring back text that was already
consumed. A stop while a start is pending (awaiting permissions) cancels the
start before any audio begins.

1. `cancelAndSever`: end the active session, cancel outright, and sever the
   callback.
2. `cancelStart`: a start is pending. Cancel it so `begin` never runs, and
   sever any recognition left over from an earlier graceful stop. No engine or
   recognizer exists yet for the pending start; the phase change makes its
   token stale.
3. `finish`: end the active session and let the recognizer deliver its final.
4. `ignore`: no active session, and the reason keeps final results flowing.
5. `severOnly`: no active session, but the transcript callback must still be
   severed and any remaining recognition task cancelled.

### 4. Transcript merging

Applies to: `DictationTranscript`

1. The transcript captures the composer text (`baseText`) and caret position
   when dictation starts, then replaces the previously inserted partial
   transcription with each newer one at that insertion point.
2. Offsets are UTF-16 code units (NSRange semantics, matching
   `UITextView.selectedRange`).
3. `merged(with:)` inserts the transcription separated by single spaces from
   adjacent non-whitespace text.
4. `merging(_:)` also returns the UTF-16 offset just past the inserted
   transcription (before any trailing separator). The caret belongs there after
   the insertion, and a committed segment's successor inserts there.

### 5. A session applies only on top of its own last merge

Applies to: `DictationSession`, `DictationSession.apply(transcription:endsSegment:to:)`

1. Each transcription applies only while the composer text is exactly what the
   previous merge produced (`lastMergedText`), or the untouched base before the
   first merge. Any other text means the user typed, or the view model replaced
   the text, during dictation. The session then reports `.diverged` without
   touching the text, so the caller can stop dictation instead of clobbering
   the edit.
2. `lastMergedText` is nil before the first merge and again right after a
   segment commit.
3. `init(baseText:insertionOffset:)` with a nil offset means no caret was
   observed yet (a programmatically restored draft never fires a selection
   change), so dictation inserts at the end of `baseText`.

### 6. Segments are committed

Applies to: `DictationSession`, `SpeechDictationController.onTranscriptChange`,
`SpeechDictationController.installRecognition(on:with:)`

The recognizer's transcript is cumulative only within a segment. After a
silence pause it finishes the utterance (`isFinal`, or a result carrying
`speechRecognitionMetadata`), and the next partial's transcript starts over.
On-device recognition finishes an utterance with a metadata-carrying result and
no `isFinal`. A segment-ending transcription is therefore committed: folded
into the base with the insertion point moved past it, so the next utterance
appends instead of replacing earlier dictated text. The Bool passed to
`onTranscriptChange` marks a segment-ending transcription, and the caller must
commit it.

### 7. Duplicate suppression is by segment identity

Applies to: `SpeechDictationController.segmentGeneration`,
`SpeechDictationController.restartSegment()`, `DictationSession`

1. The controller delivers at most one segment-ending transcription per
   recognition segment, so `DictationSession` applies every repeated
   transcription it is handed. A user who dictates the same phrase twice must
   get it twice.
2. `segmentGeneration` identifies the recognition segment (request plus task)
   whose results may act. Every `installRecognition` bumps it. A result handler
   captures the value at install and is dropped once a newer segment exists, so
   a superseded task's late final or error can neither leak old text into a
   newer session nor stop its recognition.
3. A stop does not bump it. After a graceful stop the still-current task's
   final result is delivered on purpose, until a new session installs the next
   segment or an interrupting stop severs the callback.
4. `restartSegment()` runs when the recognizer ends a segment while still
   recording. The engine is still running, so a fresh recognition segment
   starts and one mic tap survives pauses; the finished segment was already
   committed through the callback. Cancelling the old task maps each segment to
   exactly one recognition task, so a late re-delivery of the finished
   utterance (even punctuation- or recognition-corrected) is stale by
   generation and never duplicates it, while a genuinely repeated utterance in
   the new segment applies normally. After `isFinal` the old task is already
   finished; after a metadata result it is still running and must be cancelled
   so its later final targets a stale generation.
5. When a new segment cannot start, `restartSegment()` falls back to a
   `recognizerFinished` stop. The committed text means a re-tap appends instead
   of replacing.

### 8. Threading of AVFoundation and Speech callbacks

Applies to: `SpeechDictationController`

1. All controller state is MainActor-isolated (the target default).
2. Closures handed to AVFoundation and Speech run off the main queue (the
   realtime audio thread, a Speech-owned queue). They are explicitly
   `@Sendable`, never MainActor-inferred, and hop back to the main actor with
   only Sendable values.
3. The input tap runs on the realtime audio thread, so it must be `@Sendable`.
   A MainActor-inferred closure aborts there with a dispatch queue assertion.
4. The recognition result handler runs on a Speech-owned queue. It extracts
   only Sendable values there, then hops to the main actor for all state.
5. The `SFSpeechRecognizer.requestAuthorization` callback is invoked on an
   arbitrary queue and must not be MainActor-inferred.
6. Speech requires `append(_:)` on the realtime tap thread, so the tap
   captures the recognition request `nonisolated(unsafe)`.

### 9. Audio session and UI state

Applies to: `SpeechDictationController.begin(with:)`, `SpeechDictationController.isActive`,
`SpeechDictationController.unavailabilityHint`, `SpeechDictationController.recognitionTapBufferSize`

1. `startRecording` acquires the recording category and activates the shared
   session (`MediaAudioSession`) before `begin` starts the engine, even after
   video playback.
2. `isActive` is true from the mic tap on, including the starting window while
   permission prompts are pending. The mic button shows this as active, so a
   second tap during the window cancels the pending start.
3. `unavailabilityHint` is the inline hint shown in the composer when dictation
   is unavailable (permissions denied, recognizer unavailable, audio failure).
4. `recognitionTapBufferSize` is in audio frames.
5. `installRecognition` is called by `begin`, and again by `restartSegment`
   when the recognizer ends an utterance segment mid-session.

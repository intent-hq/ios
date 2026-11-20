# 0075. Dictation merge rules

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

The composer supports speech dictation (the visionOS dictation path). The recognizer sends partial and final transcriptions. The user can type, send or leave while dictation runs, and the recognizer can finish a segment after a pause. Each of these caused lost or duplicated text before.

## Decision

1. **Replace at the caret.** Each partial or final transcription replaces the previous one at the caret that was captured when dictation started. It is separated from adjacent text by single spaces.
2. **Stateless merge.** A merge always starts from the same base text, so successive partials never stack.
3. **UTF-16 offsets.** The caret offset counts UTF-16 code units, the same as `NSRange` and `selectedRange`.
4. **Never clobber typing.** When the text changed since the last merge (typed, or synced from the view model), the session reports divergence instead of merging. This also applies before the first partial and after a segment commit.
5. **No caret yet.** A restored draft never fires a selection change. With no observed caret (`nil`), dictation inserts at the end of the draft, not at offset 0.
6. **Segments.** After a silence pause the recognizer finishes the utterance (`isFinal` or a `speechRecognitionMetadata` result), and the next transcript starts over. The finished segment is committed, so the next utterance appends after it. A mid-text caret keeps its suffix across commits.
7. **Re-tap.** When the recognizer ends and the user taps the mic again, the new session starts from the committed text and caret. Dictation continues to append.
8. **Repeats.** The model applies every transcription, also one that repeats the previous segment's words. Saying a phrase twice gives it twice. The controller drops a re-delivered final by segment identity: `restartSegment()` cancels the finished segment's task, so its late finals are dropped by generation.
9. **Stop actions.** A send in the window between a graceful stop and the final result still severs the transcript callback, so a late final cannot bring back the sent text.
10. **Start window.** Any stop while `startRecording()` waits for permission prompts (second tap, disappear, scene inactive, send) cancels the pending start. Start tokens are scoped by generation: a second start during the window is refused, and a cancelled token stays stale after a new start.

## Consequences

- Dictation state lives in small value types that tests can drive without the speech framework.

## Code

- `DictationTranscript`: `merged(with:)`, `merging(_:)`
- `DictationSession`: `apply(transcription:to:)`, `MergeOutcome`
- `DictationStopAction`: `action(for:phase:)`
- `DictationStartState`: `requestStart()`, `canProceed(_:)`, `started(_:)`, `abort(_:)`, `stopped()`
- `SpeechDictationController`: `startRecording()`, `stop(reason:)`, `restartSegment()`

@testable import Intent
import Testing

/// The visionOS dictation merge rules (`DictationTranscript`): each partial
/// or final transcription replaces the previous one at the caret captured
/// when dictation started, with single-space separation from adjacent text.
struct DictationTranscriptTests {
    @Test func insertsIntoEmptyText() {
        let transcript = DictationTranscript(baseText: "", insertionOffset: 0)
        #expect(transcript.merged(with: "hello world") == "hello world")
    }

    @Test func emptyTranscriptionLeavesBaseUntouched() {
        let transcript = DictationTranscript(baseText: "draft", insertionOffset: 5)
        #expect(transcript.merged(with: "") == "draft")
    }

    @Test func longerPartialReplacesEarlierPartial() {
        // Merging is stateless over baseText, so successive partials never
        // stack: each merge starts from the same base.
        let transcript = DictationTranscript(baseText: "note:", insertionOffset: 5)
        #expect(transcript.merged(with: "hello") == "note: hello")
        #expect(transcript.merged(with: "hello there") == "note: hello there")
    }

    @Test func insertsAtCaretMidText() {
        let base = "before after"
        let transcript = DictationTranscript(baseText: base, insertionOffset: 6)
        // Caret right after "before " — trailing "after" needs a separator.
        #expect(transcript.merged(with: "middle") == "before middle after")
    }

    @Test func addsLeadingSpaceAfterNonWhitespace() {
        let transcript = DictationTranscript(baseText: "end", insertionOffset: 3)
        #expect(transcript.merged(with: "more") == "end more")
    }

    @Test func noDoubleSpaceNextToExistingWhitespace() {
        let transcript = DictationTranscript(baseText: "left ", insertionOffset: 5)
        #expect(transcript.merged(with: "right") == "left right")
    }

    @Test func noLeadingSpaceAfterNewline() {
        let transcript = DictationTranscript(baseText: "line\n", insertionOffset: 5)
        #expect(transcript.merged(with: "next") == "line\nnext")
    }

    @Test func clampsOffsetBeyondTextLength() {
        let transcript = DictationTranscript(baseText: "ab", insertionOffset: 99)
        #expect(transcript.insertionOffset == 2)
        #expect(transcript.merged(with: "cd") == "ab cd")
    }

    @Test func clampsNegativeOffset() {
        let transcript = DictationTranscript(baseText: "ab", insertionOffset: -1)
        #expect(transcript.insertionOffset == 0)
        #expect(transcript.merged(with: "cd") == "cd ab")
    }

    @Test func offsetsAreUTF16CodeUnits() {
        // "🙂" is two UTF-16 code units (matching NSRange / selectedRange
        // semantics); the caret after it is offset 2, not 1.
        let base = "🙂 tail"
        let transcript = DictationTranscript(baseText: base, insertionOffset: 2)
        #expect(transcript.merged(with: "mid") == "🙂 mid tail")
    }

    // MARK: - Stop reasons

    @Test func deliberateStopsAcceptFinalResult() {
        #expect(DictationStopReason.userTapped.acceptsFinalResult)
        #expect(DictationStopReason.recognizerFinished.acceptsFinalResult)
    }

    @Test func interruptionsRejectFinalResult() {
        #expect(!DictationStopReason.send.acceptsFinalResult)
        #expect(!DictationStopReason.viewDisappeared.acceptsFinalResult)
        #expect(!DictationStopReason.sceneInactive.acceptsFinalResult)
        #expect(!DictationStopReason.recognitionError.acceptsFinalResult)
        #expect(!DictationStopReason.textEdited.acceptsFinalResult)
    }

    // MARK: - Session merge state (typing during dictation)

    @Test func sessionMergesWhileTextUntouched() {
        var session = DictationSession(baseText: "note:", insertionOffset: 5)
        #expect(session.apply(transcription: "hello", to: "note:") == .merged("note: hello"))
        // Next partial applies over the text the previous merge produced.
        #expect(session.apply(transcription: "hello there", to: "note: hello")
            == .merged("note: hello there"))
    }

    /// Regression: text typed (or synced from the view model) during
    /// dictation must never be clobbered by the next partial — the session
    /// reports divergence instead of merging over the edit.
    @Test func sessionRefusesToClobberTextTypedDuringDictation() {
        var session = DictationSession(baseText: "", insertionOffset: 0)
        #expect(session.apply(transcription: "hello", to: "") == .merged("hello"))
        // The user typed "!" after the partial landed.
        #expect(session.apply(transcription: "hello world", to: "hello!") == .diverged)
        // Divergence applies before the first partial too.
        var fresh = DictationSession(baseText: "draft", insertionOffset: 5)
        #expect(fresh.apply(transcription: "hi", to: "draft edited") == .diverged)
    }

    /// Regression: a restored draft never fires a selection change, so no
    /// caret has been observed (`nil`) — dictation must insert at the end of
    /// the draft, not at offset 0.
    @Test func nilCaretInsertsAtEndOfRestoredDraft() {
        var session = DictationSession(baseText: "restored draft", insertionOffset: nil)
        #expect(session.apply(transcription: "hello", to: "restored draft")
            == .merged("restored draft hello"))
        // A nil caret over an empty composer behaves like a fresh session.
        var empty = DictationSession(baseText: "", insertionOffset: nil)
        #expect(empty.apply(transcription: "hi", to: "") == .merged("hi"))
    }

    // MARK: - Segment commits (pause/reset)

    /// Regression: after a silence pause the recognizer finishes the
    /// utterance (isFinal, or a `speechRecognitionMetadata` result) and the
    /// next partial's transcript starts over from the new utterance. The
    /// finished segment must be committed so the new utterance appends —
    /// before the fix it merged at the original insertion point, replacing
    /// the previously dictated text.
    @Test func pauseResetAppendsInsteadOfReplacing() {
        var session = DictationSession(baseText: "", insertionOffset: 0)
        #expect(session.apply(transcription: "hello world", endsSegment: true, to: "")
            == .merged("hello world"))
        // New utterance after the pause: the transcript is no longer
        // cumulative, yet the prior text must survive.
        #expect(session.apply(transcription: "how are you", to: "hello world")
            == .merged("hello world how are you"))
        #expect(session.apply(transcription: "how are you today", to: "hello world how are you")
            == .merged("hello world how are you today"))
    }

    /// A partial is still replaced by the final of its own segment; only
    /// after the commit does the next utterance append.
    @Test func finalReplacesOwnSegmentPartialThenCommits() {
        var session = DictationSession(baseText: "note:", insertionOffset: 5)
        #expect(session.apply(transcription: "hello", to: "note:") == .merged("note: hello"))
        #expect(session.apply(transcription: "hello world", endsSegment: true, to: "note: hello")
            == .merged("note: hello world"))
        #expect(session.apply(transcription: "again", to: "note: hello world")
            == .merged("note: hello world again"))
    }

    /// A mid-text caret keeps its suffix across commits: the next utterance
    /// inserts right after the committed one, before the trailing text.
    @Test func segmentCommitKeepsInsertionMidText() {
        var session = DictationSession(baseText: "before after", insertionOffset: 6)
        #expect(session.apply(transcription: "one", endsSegment: true, to: "before after")
            == .merged("before one after"))
        #expect(session.apply(transcription: "two", to: "before one after")
            == .merged("before one two after"))
    }

    /// Regression: when the recognizer genuinely ends on a pause and the
    /// user re-taps the mic, the fresh session starts from the committed
    /// text and caret — dictation continues appending, never replacing.
    @Test func reTapAfterRecognizerFinishedContinuesAppending() {
        var first = DictationSession(baseText: "", insertionOffset: 0)
        #expect(first.apply(transcription: "hello world", endsSegment: true, to: "")
            == .merged("hello world"))
        // The committed insertion point sits just past the inserted text;
        // the composer tracks it as the caret for the next session.
        let committedCaret = first.transcript.insertionOffset
        #expect(committedCaret == 11)
        var second = DictationSession(baseText: "hello world", insertionOffset: committedCaret)
        #expect(second.apply(transcription: "how are you", to: "hello world")
            == .merged("hello world how are you"))
    }

    /// Regression (intent-hq/ios#225 review): the model applies every
    /// transcription it is handed, including one repeating the previous
    /// segment's words — dictating the same phrase twice must yield it
    /// twice, whether the repeat surfaces as a partial or only as a
    /// segment-ending result. Duplicate suppression of a re-delivered
    /// final is the controller's job, by segment identity
    /// (`restartSegment` cancels the finished segment's task, so its late
    /// finals — even punctuation-corrected — are dropped by generation
    /// before reaching the model).
    @Test func repeatedUtteranceAppliesWhetherPartialOrFinal() {
        var session = DictationSession(baseText: "", insertionOffset: 0)
        #expect(session.apply(transcription: "send it", endsSegment: true, to: "")
            == .merged("send it"))
        // Repeat delivered only as a segment-ending result: still applies.
        #expect(session.apply(transcription: "send it", endsSegment: true, to: "send it")
            == .merged("send it send it"))
        // Repeat surfacing as a partial first: applies too.
        #expect(session.apply(transcription: "send it", to: "send it send it")
            == .merged("send it send it send it"))
    }

    /// Typing during dictation still stops the session after a commit —
    /// segment folding must not weaken divergence detection.
    @Test func divergenceStillDetectedAfterCommit() {
        var session = DictationSession(baseText: "", insertionOffset: 0)
        #expect(session.apply(transcription: "hello", endsSegment: true, to: "")
            == .merged("hello"))
        #expect(session.apply(transcription: "world", to: "hello!") == .diverged)
    }

    // MARK: - Stop actions (stop-after-stop window)

    @Test func activeSessionStopsFollowReason() {
        #expect(DictationStopAction.action(for: .userTapped, phase: .recording) == .finish)
        #expect(DictationStopAction.action(for: .send, phase: .recording) == .cancelAndSever)
        #expect(DictationStopAction.action(for: .textEdited, phase: .recording) == .cancelAndSever)
    }

    /// Regression: a send in the graceful-stop→final-result window
    /// (no longer recording) must still sever the transcript callback
    /// so the late final cannot resurrect the sent text.
    @Test func sendAfterGracefulStopStillSevers() {
        #expect(DictationStopAction.action(for: .send, phase: .idle) == .severOnly)
        #expect(DictationStopAction.action(for: .viewDisappeared, phase: .idle) == .severOnly)
        // Graceful reasons with no active session remain a no-op.
        #expect(DictationStopAction.action(for: .userTapped, phase: .idle) == .ignore)
        #expect(DictationStopAction.action(for: .recognizerFinished, phase: .idle) == .ignore)
    }

    // MARK: - Start window (authorization race)

    /// Regression: any stop while `startRecording()` is awaiting permission
    /// prompts (second tap, disappear, scene-inactive, send) must cancel the
    /// pending start so `begin` never runs a second engine or resumes capture
    /// after the composer is gone.
    @Test func stopDuringStartWindowCancelsPendingStart() throws {
        for reason: DictationStopReason in [.userTapped, .viewDisappeared, .sceneInactive, .send] {
            #expect(DictationStopAction.action(for: reason, phase: .starting) == .cancelStart)
        }

        var state = DictationStartState()
        let tokenResult = state.requestStart()
        let token = try #require(tokenResult)
        // Stop lands while authorization is pending.
        state.stopped()
        // The awaited start may not proceed and cannot reach recording.
        #expect(!state.canProceed(token))
        let reachedRecording = state.started(token)
        #expect(!reachedRecording)
        #expect(state.phase == .idle)
    }

    /// A second start during the starting window is refused, and a cancelled
    /// token stays stale even after a fresh start begins.
    @Test func startWindowTokensAreGenerationScoped() throws {
        var state = DictationStartState()
        let firstResult = state.requestStart()
        let first = try #require(firstResult)
        let reentrant = state.requestStart()
        #expect(reentrant == nil)

        state.stopped()
        let secondResult = state.requestStart()
        let second = try #require(secondResult)
        // The older attempt stays cancelled; the fresh one proceeds.
        #expect(!state.canProceed(first))
        #expect(state.canProceed(second))
        let reachedRecording = state.started(second)
        #expect(reachedRecording)
        #expect(state.phase == .recording)
        // While recording, another start is still refused.
        let whileRecording = state.requestStart()
        #expect(whileRecording == nil)
    }

    /// An uncancelled start completes; a failed one returns to idle.
    @Test func startWindowCompletesOrAborts() throws {
        var state = DictationStartState()
        let tokenResult = state.requestStart()
        let token = try #require(tokenResult)
        let reachedRecording = state.started(token)
        #expect(reachedRecording)
        #expect(state.phase == .recording)

        var failing = DictationStartState()
        let failTokenResult = failing.requestStart()
        let failToken = try #require(failTokenResult)
        failing.abort(failToken)
        #expect(failing.phase == .idle)
        // Idle again: a new start is allowed.
        let restarted = failing.requestStart()
        #expect(restarted != nil)
    }
}

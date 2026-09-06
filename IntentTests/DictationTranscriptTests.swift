import Testing
@testable import Intent

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
    @Test func stopDuringStartWindowCancelsPendingStart() {
        for reason: DictationStopReason in [.userTapped, .viewDisappeared, .sceneInactive, .send] {
            #expect(DictationStopAction.action(for: reason, phase: .starting) == .cancelStart)
        }

        var state = DictationStartState()
        let token = state.requestStart()
        #expect(token != nil)
        // Stop lands while authorization is pending.
        state.stopped()
        // The awaited start may not proceed and cannot reach recording.
        #expect(!state.canProceed(token!))
        let reachedRecording = state.started(token!)
        #expect(!reachedRecording)
        #expect(state.phase == .idle)
    }

    /// A second start during the starting window is refused, and a cancelled
    /// token stays stale even after a fresh start begins.
    @Test func startWindowTokensAreGenerationScoped() {
        var state = DictationStartState()
        let first = state.requestStart()
        #expect(first != nil)
        let reentrant = state.requestStart()
        #expect(reentrant == nil)

        state.stopped()
        let second = state.requestStart()
        #expect(second != nil)
        // The older attempt stays cancelled; the fresh one proceeds.
        #expect(!state.canProceed(first!))
        #expect(state.canProceed(second!))
        let reachedRecording = state.started(second!)
        #expect(reachedRecording)
        #expect(state.phase == .recording)
        // While recording, another start is still refused.
        let whileRecording = state.requestStart()
        #expect(whileRecording == nil)
    }

    /// An uncancelled start completes; a failed one returns to idle.
    @Test func startWindowCompletesOrAborts() {
        var state = DictationStartState()
        let token = state.requestStart()!
        let reachedRecording = state.started(token)
        #expect(reachedRecording)
        #expect(state.phase == .recording)

        var failing = DictationStartState()
        let failToken = failing.requestStart()!
        failing.abort(failToken)
        #expect(failing.phase == .idle)
        // Idle again: a new start is allowed.
        let restarted = failing.requestStart()
        #expect(restarted != nil)
    }
}

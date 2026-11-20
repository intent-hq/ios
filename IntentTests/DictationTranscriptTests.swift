@testable import Intent
import Testing

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
        let transcript = DictationTranscript(baseText: "note:", insertionOffset: 5)
        #expect(transcript.merged(with: "hello") == "note: hello")
        #expect(transcript.merged(with: "hello there") == "note: hello there")
    }

    @Test func insertsAtCaretMidText() {
        let base = "before after"
        let transcript = DictationTranscript(baseText: base, insertionOffset: 6)
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
        let base = "🙂 tail"
        let transcript = DictationTranscript(baseText: base, insertionOffset: 2)
        #expect(transcript.merged(with: "mid") == "🙂 mid tail")
    }

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

    @Test func sessionMergesWhileTextUntouched() {
        var session = DictationSession(baseText: "note:", insertionOffset: 5)
        #expect(session.apply(transcription: "hello", to: "note:") == .merged("note: hello"))
        #expect(session.apply(transcription: "hello there", to: "note: hello")
            == .merged("note: hello there"))
    }

    @Test func sessionRefusesToClobberTextTypedDuringDictation() {
        var session = DictationSession(baseText: "", insertionOffset: 0)
        #expect(session.apply(transcription: "hello", to: "") == .merged("hello"))
        #expect(session.apply(transcription: "hello world", to: "hello!") == .diverged)
        var fresh = DictationSession(baseText: "draft", insertionOffset: 5)
        #expect(fresh.apply(transcription: "hi", to: "draft edited") == .diverged)
    }

    @Test func nilCaretInsertsAtEndOfRestoredDraft() {
        var session = DictationSession(baseText: "restored draft", insertionOffset: nil)
        #expect(session.apply(transcription: "hello", to: "restored draft")
            == .merged("restored draft hello"))
        var empty = DictationSession(baseText: "", insertionOffset: nil)
        #expect(empty.apply(transcription: "hi", to: "") == .merged("hi"))
    }

    @Test func pauseResetAppendsInsteadOfReplacing() {
        var session = DictationSession(baseText: "", insertionOffset: 0)
        #expect(session.apply(transcription: "hello world", endsSegment: true, to: "")
            == .merged("hello world"))
        #expect(session.apply(transcription: "how are you", to: "hello world")
            == .merged("hello world how are you"))
        #expect(session.apply(transcription: "how are you today", to: "hello world how are you")
            == .merged("hello world how are you today"))
    }

    @Test func finalReplacesOwnSegmentPartialThenCommits() {
        var session = DictationSession(baseText: "note:", insertionOffset: 5)
        #expect(session.apply(transcription: "hello", to: "note:") == .merged("note: hello"))
        #expect(session.apply(transcription: "hello world", endsSegment: true, to: "note: hello")
            == .merged("note: hello world"))
        #expect(session.apply(transcription: "again", to: "note: hello world")
            == .merged("note: hello world again"))
    }

    @Test func segmentCommitKeepsInsertionMidText() {
        var session = DictationSession(baseText: "before after", insertionOffset: 6)
        #expect(session.apply(transcription: "one", endsSegment: true, to: "before after")
            == .merged("before one after"))
        #expect(session.apply(transcription: "two", to: "before one after")
            == .merged("before one two after"))
    }

    @Test func reTapAfterRecognizerFinishedContinuesAppending() {
        var first = DictationSession(baseText: "", insertionOffset: 0)
        #expect(first.apply(transcription: "hello world", endsSegment: true, to: "")
            == .merged("hello world"))
        let committedCaret = first.transcript.insertionOffset
        #expect(committedCaret == 11)
        var second = DictationSession(baseText: "hello world", insertionOffset: committedCaret)
        #expect(second.apply(transcription: "how are you", to: "hello world")
            == .merged("hello world how are you"))
    }

    @Test func repeatedUtteranceAppliesWhetherPartialOrFinal() {
        var session = DictationSession(baseText: "", insertionOffset: 0)
        #expect(session.apply(transcription: "send it", endsSegment: true, to: "")
            == .merged("send it"))
        #expect(session.apply(transcription: "send it", endsSegment: true, to: "send it")
            == .merged("send it send it"))
        #expect(session.apply(transcription: "send it", to: "send it send it")
            == .merged("send it send it send it"))
    }

    @Test func divergenceStillDetectedAfterCommit() {
        var session = DictationSession(baseText: "", insertionOffset: 0)
        #expect(session.apply(transcription: "hello", endsSegment: true, to: "")
            == .merged("hello"))
        #expect(session.apply(transcription: "world", to: "hello!") == .diverged)
    }

    @Test func activeSessionStopsFollowReason() {
        #expect(DictationStopAction.action(for: .userTapped, phase: .recording) == .finish)
        #expect(DictationStopAction.action(for: .send, phase: .recording) == .cancelAndSever)
        #expect(DictationStopAction.action(for: .textEdited, phase: .recording) == .cancelAndSever)
    }

    @Test func sendAfterGracefulStopStillSevers() {
        #expect(DictationStopAction.action(for: .send, phase: .idle) == .severOnly)
        #expect(DictationStopAction.action(for: .viewDisappeared, phase: .idle) == .severOnly)
        #expect(DictationStopAction.action(for: .userTapped, phase: .idle) == .ignore)
        #expect(DictationStopAction.action(for: .recognizerFinished, phase: .idle) == .ignore)
    }

    @Test func stopDuringStartWindowCancelsPendingStart() throws {
        for reason: DictationStopReason in [.userTapped, .viewDisappeared, .sceneInactive, .send] {
            #expect(DictationStopAction.action(for: reason, phase: .starting) == .cancelStart)
        }

        var state = DictationStartState()
        let tokenResult = state.requestStart()
        let token = try #require(tokenResult)
        state.stopped()
        #expect(!state.canProceed(token))
        let reachedRecording = state.started(token)
        #expect(!reachedRecording)
        #expect(state.phase == .idle)
    }

    @Test func startWindowTokensAreGenerationScoped() throws {
        var state = DictationStartState()
        let firstResult = state.requestStart()
        let first = try #require(firstResult)
        let reentrant = state.requestStart()
        #expect(reentrant == nil)

        state.stopped()
        let secondResult = state.requestStart()
        let second = try #require(secondResult)
        #expect(!state.canProceed(first))
        #expect(state.canProceed(second))
        let reachedRecording = state.started(second)
        #expect(reachedRecording)
        #expect(state.phase == .recording)
        let whileRecording = state.requestStart()
        #expect(whileRecording == nil)
    }

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
        let restarted = failing.requestStart()
        #expect(restarted != nil)
    }
}

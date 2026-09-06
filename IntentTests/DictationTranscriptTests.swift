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
    }
}

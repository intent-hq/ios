import Testing
import Textual
import UIKit

@testable import Intent

struct MarkdownTextViewTests {
    private func replaced(_ text: String) -> String {
        MarkdownTextView.replacingTaskListMarkers(text)
    }

    @Test func uncheckedMarkerBecomesEmptyCheckbox() {
        #expect(replaced("- [ ] buy milk") == "- ☐ buy milk")
    }

    @Test func checkedMarkerBecomesFilledCheckbox() {
        #expect(replaced("- [x] buy milk") == "- ☑ buy milk")
        #expect(replaced("- [X] buy milk") == "- ☑ buy milk")
    }

    @Test func starAndPlusBulletsAreSupported() {
        #expect(replaced("* [ ] a") == "* ☐ a")
        #expect(replaced("+ [x] b") == "+ ☑ b")
    }

    @Test func indentedItemsKeepIndentation() {
        #expect(replaced("  - [ ] nested") == "  - ☐ nested")
    }

    @Test func orderedTaskItemsAreConverted() {
        #expect(replaced("1. [ ] ordered") == "1. ☐ ordered")
        #expect(replaced("12) [x] ordered") == "12) ☑ ordered")
    }

    @Test func blockquotedTaskItemsAreConverted() {
        #expect(replaced("> - [x] quoted") == "> - ☑ quoted")
        #expect(replaced("> > - [ ] nested quote") == "> > - ☐ nested quote")
    }

    @Test func nestedTasksInsideListsAreConverted() {
        let text = "- [ ] parent\n    - [x] child\n\t- [ ] tabbed child"
        #expect(replaced(text) == "- ☐ parent\n    - ☑ child\n\t- ☐ tabbed child")
    }

    @Test func indentedCodeBlocksAreSkipped() {
        let text = "some prose\n\n    - [ ] example"
        #expect(replaced(text) == text)
        #expect(replaced("\t- [x] tab code") == "\t- [x] tab code")
    }

    @Test func indentedBackticksAreNotFences() {
        let text = "some prose\n\n    ```\n- [ ] real task"
        #expect(replaced(text) == "some prose\n\n    ```\n- ☐ real task")
    }

    @Test func nonTaskListLinesAreUntouched() {
        #expect(replaced("- [link](https://example.com)") == "- [link](https://example.com)")
        #expect(replaced("plain [x] text") == "plain [x] text")
        #expect(replaced("- regular item") == "- regular item")
    }

    @Test func fencedCodeBlocksAreSkipped() {
        let text = """
            - [ ] real task
            ```
            - [ ] inside fence
            ```
            - [x] after fence
            """
        let expected = """
            - ☐ real task
            ```
            - [ ] inside fence
            ```
            - ☑ after fence
            """
        #expect(replaced(text) == expected)
    }

    @Test func mismatchedFenceMarkersDoNotClose() {
        let text = "```\n~~~\n- [ ] still fenced\n```\n- [x] out"
        #expect(replaced(text) == "```\n~~~\n- [ ] still fenced\n```\n- ☑ out")
    }

    @Test func tildeFencesAreSkipped() {
        let text = "~~~\n- [ ] inside\n~~~"
        #expect(replaced(text) == text)
    }

    @Test func textWithoutBracketsIsReturnedVerbatim() {
        let text = "just some prose\nwith two lines"
        #expect(replaced(text) == text)
    }

    // MARK: - Attachment tap routing

    @Test func tappedIntentFileImageAttachmentYieldsItsImage() {
        let image = UIImage()
        let attachment = AnyAttachment(IntentFileImageAttachment(image: image, altText: "alt"))
        #expect(MarkdownTextView.lightboxImage(for: attachment) === image)
    }
}

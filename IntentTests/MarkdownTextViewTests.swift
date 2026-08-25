import Testing

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
        #expect(replaced("\t- [x] tabbed") == "\t- ☑ tabbed")
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

    @Test func tildeFencesAreSkipped() {
        let text = "~~~\n- [ ] inside\n~~~"
        #expect(replaced(text) == text)
    }

    @Test func textWithoutBracketsIsReturnedVerbatim() {
        let text = "just some prose\nwith two lines"
        #expect(replaced(text) == text)
    }
}

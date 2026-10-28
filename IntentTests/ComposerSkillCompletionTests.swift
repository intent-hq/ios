@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
struct ComposerSkillCompletionTests {
    @Test(arguments: ["👋 /review tail", "👋 /review", "👋 /review\nnext"])
    func insertionReplacesWholeTokenPreservesDraftAndContinuesAtCaret(draft: String) async {
        let completion = await makeCompletion()
        var text = draft
        let adapter = SubmittableTextView(
            text: Binding(get: { text }, set: { text = $0 }), isFocused: .constant(true), onSubmit: {}, skillCompletion: completion
        )
        let coordinator = adapter.makeCoordinator()
        let editor = SkillCompletionTextView()
        editor.delegate = coordinator
        editor.text = draft
        editor.selectedRange = NSRange(location: "👋 /re".utf16.count, length: 0)
        completion.update(from: editor)
        #expect(completion.context?.query == "re")
        #expect(completion.acceptSelection())
        let suffix = draft.hasSuffix("tail") ? " tail" : draft.hasSuffix("next") ? "\nnext" : " "
        #expect(editor.text == "👋 /release-notes" + suffix)
        #expect(text == editor.text, "Skill insertion must update the bound draft synchronously")
        #expect(editor.selectedRange.location == "👋 /release-notes ".utf16.count)
        editor.insertText("more ")
        #expect(text.contains("more "))
        #expect(completion.context == nil)
        #expect(editor.isFirstResponder)
    }

    @Test func ignoresStaleContextNonemptySelectionAndMarkedText() async {
        let completion = await makeCompletion()
        let editor = SkillCompletionTextView()
        editor.text = "/re"
        editor.selectedRange = NSRange(location: 3, length: 0)
        completion.update(from: editor)
        editor.text = "Replaced externally"
        #expect(!completion.acceptSelection())
        #expect(editor.text == "Replaced externally")
        editor.text = "/re"
        editor.selectedRange = NSRange(location: 1, length: 2)
        completion.update(from: editor)
        #expect(completion.context == nil)
        editor.selectedRange = NSRange(location: 3, length: 0)
        editor.setMarkedText("view", selectedRange: NSRange(location: 4, length: 0))
        completion.update(from: editor)
        #expect(completion.context == nil)
    }

    @Test func keyboardSelectionWrapsAndEscapeStaysDismissedUntilContextChanges() async {
        let completion = await makeCompletion()
        let editor = SkillCompletionTextView()
        editor.text = "/"
        editor.selectedRange = NSRange(location: 1, length: 0)
        completion.update(from: editor)
        #expect(completion.selectedSkill?.name == "code-review")
        completion.moveSelection(by: -1)
        #expect(completion.selectedSkill?.name == "release-notes")
        completion.moveSelection(by: 1)
        #expect(completion.selectedSkill?.name == "code-review")
        completion.dismiss()
        completion.update(from: editor)
        #expect(completion.context == nil)
        editor.text = "/rel"
        editor.selectedRange = NSRange(location: 4, length: 0)
        completion.update(from: editor)
        #expect(completion.context?.query == "rel")
        #expect(completion.selectedSkill?.name == "release-notes")
    }

    private func makeCompletion() async -> ComposerSkillCompletion {
        let connection = FakeConnectionManager()
        connection.responseMap["skill.list"] = ["code-review", "release-notes"].map { name in
            ["name": name, "description": "", "location": "/\(name)/SKILL.md", "scope": "user"]
        }
        let completion = ComposerSkillCompletion()
        await completion.catalog.load(workspaceId: "workspace", agentId: "agent", connection: connection)
        return completion
    }
}

private final class SkillCompletionTextView: KeyCommandTextView {
    override var isFirstResponder: Bool { true }
}

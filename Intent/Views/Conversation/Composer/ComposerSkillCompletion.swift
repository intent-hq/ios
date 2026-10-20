import Observation
import UIKit

@MainActor
@Observable final class ComposerSkillCompletion {
    let catalog = SkillCatalogStore()
    private(set) var context: SlashSkillContext?
    private(set) var selectedIndex = 0
    @ObservationIgnored private weak var editor: UITextView?
    @ObservationIgnored private var dismissedContext: SlashSkillContext?

    var matches: [SkillInfo] { SlashSkillContext.ranked(catalog.skills, query: context?.query ?? "") }
    var selectedSkill: SkillInfo? {
        let matches = matches
        return matches.indices.contains(selectedIndex) ? matches[selectedIndex] : matches.first
    }

    func update(from editor: UITextView) {
        self.editor = editor
        let next = editor.isFirstResponder && editor.markedTextRange == nil
            ? SlashSkillContext.find(in: editor.text, selection: editor.selectedRange) : nil
        if next != dismissedContext { dismissedContext = nil }
        let visible = next == dismissedContext ? nil : next
        if context != visible { selectedIndex = 0 }
        context = visible
    }

    func dismiss() {
        dismissedContext = context
        context = nil
    }

    func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + matches.count) % matches.count
    }

    @discardableResult
    func acceptSelection() -> Bool {
        guard context != nil, let selectedSkill else { return false }
        return insert(selectedSkill)
    }

    @discardableResult
    func insert(_ skill: SkillInfo) -> Bool {
        guard let editor, editor.isEditable, editor.isFirstResponder, editor.markedTextRange == nil,
              let context, context == SlashSkillContext.find(in: editor.text, selection: editor.selectedRange),
              catalog.skills.contains(skill), let range = Range(context.range, in: editor.text) else { return false }
        let suffix = editor.text[range.upperBound...]
        let needsSpace = suffix.isEmpty
        editor.selectedRange = context.range
        editor.insertText("/\(skill.name)" + (needsSpace ? " " : ""))
        if let separator = suffix.first {
            editor.selectedRange = NSRange(location: editor.selectedRange.location + String(separator).utf16.count, length: 0)
        }
        update(from: editor)
        return true
    }
}

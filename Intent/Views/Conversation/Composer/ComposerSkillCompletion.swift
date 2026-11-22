import Observation
import UIKit

@MainActor
@Observable final class ComposerSkillCompletion {
    let catalog = SkillCatalogStore()
    private(set) var context: SlashSkillContext?
    private(set) var selectedIndex = 0
    private(set) var contextStartsPrompt = false
    var builtInCommands: [SlashBuiltInCommand] = []
    @ObservationIgnored private weak var editor: UITextView?
    @ObservationIgnored private var dismissedContext: SlashSkillContext?
    @ObservationIgnored private var ranking: Ranking?
    @ObservationIgnored private(set) var rankingCount = 0

    private struct Ranking {
        let skills: [SkillInfo]
        let index: SkillSearchIndex
        let query: String
        let matches: [SkillInfo]
    }

    var commandMatches: [SlashBuiltInCommand] {
        guard let context else { return [] }
        return SlashBuiltInCommand.ranked(builtInCommands, query: context.query, startsPrompt: contextStartsPrompt)
    }

    var entries: [SlashCompletionEntry] {
        commandMatches.map(SlashCompletionEntry.command) + matches.map(SlashCompletionEntry.skill)
    }

    var selectedEntry: SlashCompletionEntry? {
        let entries = entries
        return entries.indices.contains(selectedIndex) ? entries[selectedIndex] : entries.first
    }

    var matches: [SkillInfo] {
        let skills = SlashBuiltInCommand.unshadowed(catalog.skills, by: builtInCommands)
        let query = context?.query ?? ""
        if let ranking, ranking.query == query, ranking.skills == skills { return ranking.matches }
        let index = ranking.flatMap { $0.skills == skills ? $0.index : nil } ?? SkillSearchIndex(skills)
        let matches = index.ranked(query: query)
        rankingCount += 1
        ranking = Ranking(skills: skills, index: index, query: query, matches: matches)
        return matches
    }
    var selectedSkill: SkillInfo? {
        if case let .skill(skill) = selectedEntry { return skill }
        return nil
    }

    func update(from editor: UITextView) {
        self.editor = editor
        let next = editor.isFirstResponder && editor.markedTextRange == nil
            ? SlashSkillContext.find(in: editor.text, selection: editor.selectedRange) : nil
        if next != dismissedContext { dismissedContext = nil }
        let visible = next == dismissedContext ? nil : next
        if context != visible { selectedIndex = 0 }
        context = visible
        contextStartsPrompt = visible.map { Self.startsPrompt(editor.text, at: $0.range) } ?? false
    }

    func dismiss() {
        dismissedContext = context
        context = nil
    }

    func moveSelection(by delta: Int) {
        let count = entries.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    @discardableResult
    func acceptSelection() -> Bool {
        guard context != nil, let selectedEntry else { return false }
        return insertEntry(selectedEntry)
    }

    @discardableResult
    func insert(_ skill: SkillInfo) -> Bool {
        insertEntry(.skill(skill))
    }

    @discardableResult
    func insert(_ command: SlashBuiltInCommand) -> Bool {
        insertEntry(.command(command))
    }

    @discardableResult
    private func insertEntry(_ entry: SlashCompletionEntry) -> Bool {
        guard let editor, editor.isEditable, editor.isFirstResponder, editor.markedTextRange == nil,
              let context, context == SlashSkillContext.find(in: editor.text, selection: editor.selectedRange),
              isAvailable(entry), let range = Range(context.range, in: editor.text) else { return false }
        let suffix = editor.text[range.upperBound...]
        let needsSpace = suffix.isEmpty
        editor.selectedRange = context.range
        editor.insertText("/\(entry.name)" + (needsSpace ? " " : ""))
        if let separator = suffix.first {
            editor.selectedRange = NSRange(location: editor.selectedRange.location + String(separator).utf16.count, length: 0)
        }
        update(from: editor)
        return true
    }

    private func isAvailable(_ entry: SlashCompletionEntry) -> Bool {
        switch entry {
        case let .command(command): commandMatches.contains(command)
        case let .skill(skill): catalog.skills.contains(skill)
        }
    }

    nonisolated static func startsPrompt(_ text: String, at range: NSRange) -> Bool {
        guard let start = Range(range, in: text)?.lowerBound else { return false }
        return text[..<start].unicodeScalars.allSatisfy(\.properties.isWhitespace)
    }
}

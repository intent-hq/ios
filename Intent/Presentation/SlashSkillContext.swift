import Foundation

struct SlashSkillContext: Equatable {
    let query: String
    let range: NSRange

    static func find(in text: String, selection: NSRange) -> Self? {
        guard selection.length == 0, let caret = Range(selection, in: text)?.lowerBound else { return nil }
        let prefix = text[..<caret]
        let start = prefix.lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
        guard start < caret, text[start] == "/" else { return nil }
        let end = text[caret...].firstIndex(where: \.isWhitespace) ?? text.endIndex
        let token = text[text.index(after: start)..<end]
        guard !token.contains("/"), !token.contains("\\") else { return nil }
        return Self(query: String(text[text.index(after: start)..<caret]), range: NSRange(start..<end, in: text))
    }

    static func ranked(_ skills: [SkillInfo], query: String) -> [SkillInfo] {
        SkillSearchIndex(skills).ranked(query: query)
    }
}

/// Lowercases every name and description once per catalog so each query only matches and sorts.
struct SkillSearchIndex {
    private enum MatchRank: Int {
        case exact, prefix, name, description
    }

    private struct Entry {
        let skill: SkillInfo
        let name: String
        let description: String
    }

    private let entries: [Entry]

    init(_ skills: [SkillInfo]) {
        entries = skills.map { Entry(skill: $0, name: $0.name.lowercased(), description: $0.description.lowercased()) }
    }

    func ranked(query: String) -> [SkillInfo] {
        let query = query.lowercased()
        let ranked = entries.compactMap { entry -> (Entry, MatchRank)? in
            let rank: MatchRank
            if query.isEmpty || entry.name == query {
                rank = .exact
            } else if entry.name.hasPrefix(query) {
                rank = .prefix
            } else if entry.name.contains(query) {
                rank = .name
            } else if entry.description.contains(query) {
                rank = .description
            } else {
                return nil
            }
            return (entry, rank)
        }
        return ranked.sorted { left, right in
            if left.1 != right.1 { return left.1.rawValue < right.1.rawValue }
            if left.0.name != right.0.name { return left.0.name < right.0.name }
            if left.0.skill.name != right.0.skill.name { return left.0.skill.name < right.0.skill.name }
            return left.0.skill.location < right.0.skill.location
        }
        .map(\.0.skill)
    }
}

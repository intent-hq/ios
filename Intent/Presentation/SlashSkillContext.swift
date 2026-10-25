import Foundation

struct SlashSkillContext: Equatable {
    private enum MatchRank: Int {
        case exact, prefix, name, description
    }

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
        let query = query.lowercased()
        let ranked = skills.compactMap { skill -> (SkillInfo, MatchRank)? in
            let name = skill.name.lowercased()
            let rank: MatchRank
            if query.isEmpty || name == query {
                rank = .exact
            } else if name.hasPrefix(query) {
                rank = .prefix
            } else if name.contains(query) {
                rank = .name
            } else if skill.description.lowercased().contains(query) {
                rank = .description
            } else {
                return nil
            }
            return (skill, rank)
        }
        return ranked.sorted { left, right in
            if left.1 != right.1 { return left.1.rawValue < right.1.rawValue }
            if left.0.name.lowercased() != right.0.name.lowercased() { return left.0.name.lowercased() < right.0.name.lowercased() }
            if left.0.name != right.0.name { return left.0.name < right.0.name }
            return left.0.location < right.0.location
        }
        .map(\.0)
    }
}

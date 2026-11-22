import Foundation

nonisolated struct SlashBuiltInCommand: Identifiable, Hashable, Sendable {
    let name: String
    let description: String

    var id: String { "builtin:\(name)" }

    static let goal = Self(name: "goal", description: String(localized: "Pin a goal to this conversation"))

    static func ranked(_ commands: [Self], query: String, startsPrompt: Bool) -> [Self] {
        guard startsPrompt else { return [] }
        let normalized = query.lowercased()
        return commands.filter { $0.name.lowercased().hasPrefix(normalized) }
    }

    static func unshadowed(_ skills: [SkillInfo], by commands: [Self]) -> [SkillInfo] {
        guard !commands.isEmpty else { return skills }
        let names = Set(commands.map { $0.name.lowercased() })
        return skills.filter { !names.contains($0.name.lowercased()) }
    }
}

nonisolated enum SlashCompletionEntry: Identifiable, Hashable, Sendable {
    case command(SlashBuiltInCommand)
    case skill(SkillInfo)

    var id: String {
        switch self {
        case let .command(command): command.id
        case let .skill(skill): skill.id
        }
    }

    var name: String {
        switch self {
        case let .command(command): command.name
        case let .skill(skill): skill.name
        }
    }
}

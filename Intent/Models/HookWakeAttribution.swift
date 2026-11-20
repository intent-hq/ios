import Foundation

enum HookPostWakeState: Equatable {
    case continues
    case retired
    case unreported

    init(reportedActive: Bool) {
        self = reportedActive ? .continues : .retired
    }
}

struct HookWakeAttribution: Equatable {
    let hookId: String
    let rawName: String
    let displayName: String
    let reason: String
    let postWakeState: HookPostWakeState

    private static let maxNameLength = 20
    private static let fallbackName = "Hook"

    static func from(_ metadata: [String: AnyCodable]) -> Self? {
        guard metadata["type"]?.stringValue == "hook_wake" else { return nil }
        let hookId = (metadata["hookId"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = metadata["hookName"]?.stringValue ?? ""
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? fallbackName : trimmedName
        let displayName = name.count > maxNameLength
            ? String(name.prefix(maxNameLength - 1)) + "…"
            : name
        let postWakeState: HookPostWakeState
        if case let .some(.value(value)) = metadata["hookStillActive"]?.boolValue {
            postWakeState = HookPostWakeState(reportedActive: value)
        } else {
            postWakeState = .unreported
        }
        return Self(
            hookId: hookId,
            rawName: rawName,
            displayName: displayName,
            reason: metadata["reason"]?.stringValue ?? "",
            postWakeState: postWakeState
        )
    }

    var stateLabel: String {
        if reason == "evicted" { return "woke the agent and is now retired" }
        if reason == "dispatched" {
            switch postWakeState {
            case .continues:
                return "woke the agent and will continue to run"
            case .retired:
                return "woke the agent and is now retired"
            case .unreported:
                break
            }
        }
        return "woke the agent"
    }

    static func stripPrefix(_ text: String, attribution: Self? = nil) -> String {
        if let rawName = attribution?.rawName, !rawName.isEmpty {
            let literal = "[Background hook \"\(rawName)\"]"
            if text.hasPrefix(literal) {
                return String(text.dropFirst(literal.count))
                    .replacingOccurrences(
                        of: "^\\s*",
                        with: "",
                        options: .regularExpression
                    )
            }
        }
        return text.replacingOccurrences(
            of: "^\\[Background hook \"[^\"]*\"\\]\\s*",
            with: "",
            options: .regularExpression
        )
    }

    static func stripStateNote(_ text: String) -> String {
        text.replacingOccurrences(
            of: "(?:\\n[ \\t]*\\n|^)\\[This hook [^\\n]*\\]\\s*$",
            with: "",
            options: .regularExpression
        )
    }

    static func displayText(_ text: String, attribution: Self? = nil) -> String {
        stripStateNote(stripPrefix(text, attribution: attribution))
    }
}

extension ConversationMessage {
    var hookWakeAttribution: HookWakeAttribution? {
        if let attribution = HookWakeAttribution.from(metadata) { return attribution }
        for block in contentBlocks where block.type == .text {
            if let attribution = HookWakeAttribution.from(block.messageMetadata) {
                return attribution
            }
        }
        return nil
    }
}

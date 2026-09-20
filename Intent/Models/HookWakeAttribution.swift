import Foundation

enum HookPostWakeState: Equatable {
    case continues
    case retired
    case unreported

    init(reportedActive: Bool) {
        self = reportedActive ? .continues : .retired
    }
}

/// Attribution for background-hook wake messages (PROTOCOL §5.40). The daemon
/// tags user-role rows delivered by a background hook wake with
/// `{ type: "hook_wake", hookId, hookName, reason, hookStillActive? }` — on
/// the row's `metadata`, on the persisted text block's `messageMetadata`, and
/// on queued entries' `messageMetadata`. Extraction is metadata-first with
/// graceful fallback: absent or malformed metadata returns nil so the message
/// renders exactly as before (FE parity: `hook-wake-attribution.ts`).
struct HookWakeAttribution: Equatable {
    /// Hook id (may be empty when the daemon omitted it).
    let hookId: String
    /// Verbatim hook name from metadata (empty when absent) — untrimmed and
    /// untruncated, exactly as the daemon used it in the literal wake prefix.
    /// Used to build the exact literal prefix for metadata-first stripping.
    let rawName: String
    /// Display name for the hook ("Hook" fallback, truncated to ~20 chars).
    let displayName: String
    /// Wake reason (`dispatched` / `evicted` / …; empty when absent).
    let reason: String
    /// Whether the hook remains active after a `dispatched` wake (perpetual
    /// re-arm) or is retired. Nil on other reasons and on messages persisted
    /// before the daemon added the field (presence-detected additive field).
    let postWakeState: HookPostWakeState

    private static let maxNameLength = 20
    private static let fallbackName = "Hook"

    /// Extracts hook-wake attribution from an opaque metadata dictionary.
    /// Returns nil unless `metadata.type == "hook_wake"`.
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

    /// Post-fire state suffix for the attribution header: on dispatched wakes
    /// carrying the additive `hookStillActive` field, say whether the hook
    /// re-armed or retired; an eviction always retires the hook, so its wake
    /// shows the retired suffix unconditionally. Otherwise fall back to the
    /// plain "woke the agent" (FE parity: HookWakeAttributionHeader).
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

    /// Literal wake prefix the daemon prepends to hook wake message content:
    /// `[Background hook "<name>"] `. Display-only strip — the stored message
    /// text is never mutated. Metadata-first: when the attribution carries the
    /// verbatim (untrimmed) hook name, strip the exact literal prefix built
    /// from it (works for names containing double quotes or edge whitespace,
    /// which defeat the regex); otherwise fall back to the regex. Returns the
    /// input unchanged when no prefix matches.
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

    /// Trailing state note the daemon appends to dispatched/evicted hook wake
    /// messages as a final single-line paragraph starting with `[This hook`
    /// and ending with `]`. The attribution header conveys the post-fire
    /// state instead. Also matches a note constituting the whole string.
    /// Display-only strip; returns the input unchanged when no match exists.
    static func stripStateNote(_ text: String) -> String {
        text.replacingOccurrences(
            of: "(?:\\n[ \\t]*\\n|^)\\[This hook [^\\n]*\\]\\s*$",
            with: "",
            options: .regularExpression
        )
    }

    /// Display text for a hook-wake body: prefix and state note stripped.
    static func displayText(_ text: String, attribution: Self? = nil) -> String {
        stripStateNote(stripPrefix(text, attribution: attribution))
    }
}

extension ConversationMessage {
    /// Hook-wake attribution for this row: the daemon tags the row's
    /// `metadata` AND the persisted text block's `messageMetadata` — check
    /// both so older rows missing one surface still render the header
    /// (FE parity: ChatMessage.svelte).
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

import Foundation

/// Attribution for centralized PR-monitor wake messages (PROTOCOL §5.42).
/// The daemon tags user-role rows delivered by a PR-monitor wake with
/// `{ type: "pr_monitor_wake", monitorId, repo, prNumber, reason, url? }` —
/// on the row's `metadata`, on the persisted text block's `messageMetadata`,
/// and on queued entries' `messageMetadata`. Extraction is metadata-first
/// with graceful fallback: absent or malformed metadata returns nil so the
/// message renders exactly as before (FE parity:
/// `pr-monitor-wake-attribution.ts`).
struct PrMonitorWakeAttribution: Equatable {
    /// Monitor id (may be empty when the daemon omitted it).
    let monitorId: String
    /// `owner/repo` of the monitored PR.
    let repo: String
    /// PR number.
    let prNumber: Int
    /// The PR's HTML URL, when the daemon had a baseline snapshot to read it from.
    let url: String?

    /// Extracts PR-monitor wake attribution from an opaque metadata
    /// dictionary. Returns nil unless `metadata.type == "pr_monitor_wake"`
    /// with a usable `repo` + `prNumber` (both are required to build the PR link).
    static func from(_ metadata: [String: AnyCodable]?) -> PrMonitorWakeAttribution? {
        guard let metadata, metadata["type"]?.stringValue == "pr_monitor_wake" else { return nil }
        let repo = (metadata["repo"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty,
              let prNumber = metadata["prNumber"]?.intValue, prNumber > 0 else { return nil }
        let monitorId = (metadata["monitorId"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawUrl = (metadata["url"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PrMonitorWakeAttribution(
            monitorId: monitorId,
            repo: repo,
            prNumber: prNumber,
            url: rawUrl.isEmpty ? nil : rawUrl)
    }

    /// The PR HTML URL to open: metadata `url` when the daemon provided it,
    /// else the GitHub fallback built from `repo` + `prNumber` (same fallback
    /// as MonitoredPrsRow) — so the chip works before the daemon ships `url`.
    var resolvedUrl: String {
        url ?? "https://github.com/\(repo)/pull/\(prNumber)"
    }

    /// Chip label following the MonitoredPrsRow convention: `#N`, prefixed
    /// with `owner/repo: ` only when the PR's repo differs from the workspace
    /// repository (or the workspace repository is unknown — then plain `#N`).
    func chipLabel(workspaceRepo: String?) -> String {
        let number = "#\(prNumber)"
        if let workspaceRepo, repo != workspaceRepo {
            return "\(repo): \(number)"
        }
        return number
    }

    /// Literal wake prefix the daemon prepends to PR-monitor wake message
    /// content: `[PR monitor <owner/repo>#<n>] `. Display-only strip — the
    /// stored message text is never mutated. Returns the input unchanged when
    /// no prefix matches.
    static func stripPrefix(_ text: String) -> String {
        text.replacingOccurrences(
            of: "^\\[PR monitor [^\\]]*\\]\\s*",
            with: "",
            options: .regularExpression)
    }

    /// Display text for a PR-monitor wake body: prefix stripped.
    static func displayText(_ text: String) -> String {
        stripPrefix(text)
    }
}

extension ConversationMessage {
    /// PR-monitor wake attribution for this row: the daemon tags the row's
    /// `metadata` AND the persisted text block's `messageMetadata` — check
    /// both so older rows missing one surface still render the header
    /// (FE parity: ChatMessage.svelte).
    var prMonitorWakeAttribution: PrMonitorWakeAttribution? {
        if let attribution = PrMonitorWakeAttribution.from(metadata) { return attribution }
        for block in contentBlocks ?? [] where block.type == .text {
            if let attribution = PrMonitorWakeAttribution.from(block.messageMetadata) {
                return attribution
            }
        }
        return nil
    }
}

extension QueuedMessage {
    /// PR-monitor wake attribution for a queued entry
    /// (`messageMetadata.type == "pr_monitor_wake"`, PROTOCOL §5.42).
    var prMonitorWakeAttribution: PrMonitorWakeAttribution? {
        PrMonitorWakeAttribution.from(messageMetadata)
    }
}

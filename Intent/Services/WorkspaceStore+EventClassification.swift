import Foundation

extension WorkspaceStore {
    // MARK: - Event classification

    /// A trailing colon denotes a channel prefix; other entries name exact events.
    nonisolated static let handledChannels = ["workspace:", "agent:", "host:members-changed"]

    nonisolated static let refetchEventTypes: Set<String> = [
        "host:members-changed",
        "workspace:created", "workspace:deleted",
        "workspace:activity-changed", "workspace:displayStatus-changed",
        "workspace:attention-changed",
        "agent:started", "agent:completed", "agent:failed", "agent:created",
        "agent:deleted", "agent:idle", "agent:status-changed", "agent:renamed"
    ]

    nonisolated static let patchInPlaceEventTypes: Set<String> = [
        "workspace:waiting-changed"
    ]

    nonisolated static let ignoredEventTypes: Set<String> = [
        "workspace:delete-scheduled", "workspace:delete-cancelled",
        "workspace:opened", "workspace:closed", "workspace:activity",
        "workspace:setup:started", "workspace:setup:completed",
        "workspace:transfer:failed", "workspace:transfer:progress",
        "workspace:transfer:ready", "workspace:tokenUsage-changed",
        "workspace:context-changed",
        "agent:attention-requested", "agent:delete-cancelled",
        "agent:delete-scheduled", "agent:delivery-confirmed",
        "agent:event-delivery-failed", "agent:event-delivery-timeout",
        "agent:last-message", "agent:message", "agent:message:delivery-failed",
        "agent:message:received", "agent:message:sent",
        "agent:permission:request", "agent:permission:resolved",
        "agent:process:evicted", "agent:process:queued", "agent:process:resumed",
        "agent:queue:processing", "agent:queue:processing-cancelled",
        "agent:queue:stale-message", "agent:queue:updated",
        "agent:restored", "agent:retired", "agent:session-stats-changed",
        "agent:stream:activity", "agent:stream:end", "agent:stream:start",
        "agent:stream:status", "agent:subscribed", "agent:subscriptions-changed",
        "agent:subscriptions-restored", "agent:tool:call", "agent:unsubscribed",
        "agent:updated", "agent:user-message:sent", "agent:woken-by-subscription"
    ]

    nonisolated static let workspaceUpdatedChangeKeyClassification: [String: EventClassification] = [
        "lastActivity": .patchInPlace,
        "activePullRequest": .refetch, "archived": .refetch, "archivedAt": .refetch,
        "attention": .refetch, "autoCommitEnabled": .refetch, "autoUnarchive": .refetch,
        "baseCommitSha": .refetch, "baseRef": .refetch, "branch": .refetch,
        "browserClientId": .refetch, "defaultModel": .refetch, "isRemote": .refetch,
        "mcpServerToggled": .refetch, "members": .refetch, "path": .refetch,
        "prNumber": .refetch, "prStatus": .refetch, "prUrl": .refetch,
        "pullRequests": .refetch, "removedPrincipalId": .refetch,
        "repositoryName": .refetch, "repositoryOwner": .refetch,
        "repositoryPath": .refetch, "scope": .refetch, "setupScript": .refetch,
        "skipIsolation": .refetch, "status": .refetch, "statusImageAssetId": .refetch,
        "statusMessage": .refetch, "tags": .refetch, "title": .refetch,
        "worktreePath": .refetch
    ]

    nonisolated static func classify(
        type: String,
        data: [String: Any]? // swiftlint:disable:this discouraged_optional_collection
    ) -> EventClassification? {
        if refetchEventTypes.contains(type) { return .refetch }
        if patchInPlaceEventTypes.contains(type) { return .patchInPlace }
        if ignoredEventTypes.contains(type) { return .ignore }
        if type == "workspace:updated" {
            guard let changes = data?["changes"] as? [String: Any], !changes.isEmpty else {
                return .refetch
            }
            let allPatched = changes.keys.allSatisfy { key in
                workspaceUpdatedChangeKeyClassification[key] == .patchInPlace
            }
            return allPatched ? .patchInPlace : .refetch
        }
        return nil
    }
}

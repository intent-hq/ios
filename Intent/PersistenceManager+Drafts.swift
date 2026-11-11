import Foundation

extension PersistenceManager {
    // MARK: - Draft Messages

    private static let draftPrefix = "draft_"
    private static let legacyDraftOwnerKey = "legacyDraftOwner"

    private static func draftKey(workspaceId: String, agentId: String, backendID: BackendID?) -> String {
        if let backendID {
            return "\(draftPrefix)\(backendID.connectionID.uuidString)_\(workspaceId)_\(agentId)"
        }
        return "\(draftPrefix)\(workspaceId)_\(agentId)"
    }

    func saveDraft(_ text: String, workspaceId: String, agentId: String, backendID: BackendID? = nil) {
        migrateLegacyDraft(workspaceId: workspaceId, agentId: agentId, backendID: backendID)
        let key = Self.draftKey(workspaceId: workspaceId, agentId: agentId, backendID: backendID)
        if text.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(text, forKey: key)
        }
    }

    func loadDraft(workspaceId: String, agentId: String, backendID: BackendID? = nil) -> String {
        migrateLegacyDraft(workspaceId: workspaceId, agentId: agentId, backendID: backendID)
        let key = Self.draftKey(workspaceId: workspaceId, agentId: agentId, backendID: backendID)
        return defaults.string(forKey: key) ?? ""
    }

    /// Remember the legacy owner across connection switches and process restarts.
    /// Missing/failed registry reads leave drafts untouched until ownership resolves.
    private func migrateLegacyDraft(workspaceId: String, agentId: String, backendID: BackendID?) {
        guard let backendID else { return }
        preserveLegacyDraftOwner()
        guard defaults.string(forKey: Self.legacyDraftOwnerKey) == backendID.connectionID.uuidString else { return }
        let legacyKey = Self.draftKey(workspaceId: workspaceId, agentId: agentId, backendID: nil)
        guard let legacy = defaults.string(forKey: legacyKey) else { return }
        let key = Self.draftKey(workspaceId: workspaceId, agentId: agentId, backendID: backendID)
        // A scoped value is newer. Consume the legacy value even when it loses.
        if defaults.object(forKey: key) == nil {
            defaults.set(legacy, forKey: key)
        }
        defaults.removeObject(forKey: legacyKey)
    }

    /// Capture the previous active backend before a window changes the last-used pointer.
    func preserveLegacyDraftOwner() {
        guard defaults.string(forKey: Self.legacyDraftOwnerKey) == nil,
              let activeID = activeConnection()?.id else { return }
        defaults.set(activeID.uuidString, forKey: Self.legacyDraftOwnerKey)
    }

    func clearDraft(workspaceId: String, agentId: String, backendID: BackendID? = nil) {
        migrateLegacyDraft(workspaceId: workspaceId, agentId: agentId, backendID: backendID)
        let key = Self.draftKey(workspaceId: workspaceId, agentId: agentId, backendID: backendID)
        defaults.removeObject(forKey: key)
    }
}

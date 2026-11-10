import Foundation

extension PersistenceManager {
    // MARK: - Draft Messages

    private static let draftPrefix = "draft_"

    private static func draftKey(workspaceId: String, agentId: String, backendID: BackendID?) -> String {
        if let backendID {
            return "\(draftPrefix)\(backendID.connectionID.uuidString)_\(workspaceId)_\(agentId)"
        }
        return "\(draftPrefix)\(workspaceId)_\(agentId)"
    }

    func saveDraft(_ text: String, workspaceId: String, agentId: String, backendID: BackendID? = nil) {
        let key = Self.draftKey(workspaceId: workspaceId, agentId: agentId, backendID: backendID)
        if text.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(text, forKey: key)
        }
    }

    func loadDraft(workspaceId: String, agentId: String, backendID: BackendID? = nil) -> String {
        let key = Self.draftKey(workspaceId: workspaceId, agentId: agentId, backendID: backendID)
        return defaults.string(forKey: key) ?? ""
    }

    func clearDraft(workspaceId: String, agentId: String, backendID: BackendID? = nil) {
        let key = Self.draftKey(workspaceId: workspaceId, agentId: agentId, backendID: backendID)
        defaults.removeObject(forKey: key)
    }
}

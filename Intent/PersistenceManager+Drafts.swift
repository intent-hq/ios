import Foundation

extension PersistenceManager {
    // MARK: - Draft Messages

    private static let draftPrefix = "draft_"

    func saveDraft(_ text: String, workspaceId: String, agentId: String) {
        let key = "\(Self.draftPrefix)\(workspaceId)_\(agentId)"
        if text.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(text, forKey: key)
        }
    }

    func loadDraft(workspaceId: String, agentId: String) -> String {
        let key = "\(Self.draftPrefix)\(workspaceId)_\(agentId)"
        return defaults.string(forKey: key) ?? ""
    }

    func clearDraft(workspaceId: String, agentId: String) {
        let key = "\(Self.draftPrefix)\(workspaceId)_\(agentId)"
        defaults.removeObject(forKey: key)
    }
}

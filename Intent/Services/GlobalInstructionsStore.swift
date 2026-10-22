import Foundation
import Observation

@MainActor
@Observable final class GlobalInstructionsStore {
    private struct Rule: Decodable, Equatable {
        let enabled: Bool
        let content: String
    }

    var content = ""
    var enabled = false
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private var savedRule: Rule?
    private let connection: ConnectionManagerRouting

    var isLoaded: Bool { savedRule != nil }
    var hasChanges: Bool {
        guard let savedRule else { return false }
        return savedRule != Rule(enabled: enabled, content: content)
    }

    init(connection: ConnectionManagerRouting) {
        self.connection = connection
    }

    func load() async {
        guard !isLoading, !isSaving, !isLoaded else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await connection.request("rules.get", params: Self.parameters)
            let rule = try JSONDecoder().decode(Rule.self, from: JSONSerialization.data(withJSONObject: result))
            content = rule.content
            enabled = rule.enabled
            savedRule = rule
        } catch {
            errorMessage = "Couldn’t load global instructions from this host. Check your connection and retry."
        }
    }

    func save() async {
        guard isLoaded, hasChanges, !isSaving, !isLoading else { return }
        let submitted = Rule(enabled: enabled, content: content)
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            var params = Self.parameters
            params["content"] = submitted.content
            params["enabled"] = submitted.enabled
            _ = try await connection.request("rules.update", params: params)
            savedRule = submitted
        } catch {
            errorMessage = "Couldn’t save global instructions. Your draft is still here. Check your connection and host permissions, then retry."
        }
    }

    private static var parameters: [String: Any] {
        ["workspaceId": "global", "ruleType": "base-system-prompt"]
    }
}

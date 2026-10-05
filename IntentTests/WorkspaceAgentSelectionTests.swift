import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceAgentSelectionTests {
    private let backendID = BackendID(UUID())
    private let implementor = SpecialistInfo(id: "implementor", name: "Implementor", description: "Builds")
    private let verifier = SpecialistInfo(id: "verifier", name: "Verifier", description: "Reviews")
    private let auggie = ProviderInfo(id: "auggie", authenticated: .signedIn)
    private let codex = ProviderInfo(id: "codex", authenticated: .signedIn)
    private let named = ModelInfo(id: "shared-id", name: "Named", provider: "codex", effortLevels: ["low", "high"])

    @Test func choicesSurviveNewSelectionAndPersistenceInstances() throws {
        try withPersistence { persistence in
            let first = configuredSelection(persistence)
            let reopenedStore = PersistenceManager(defaults: persistence.defaults, keychainStorage: EphemeralKeychainStorage())
            let reopened = WorkspaceAgentSelection(backendID: backendID, persistence: reopenedStore)
            reconcile(reopened)
            #expect(reopened.specialist == verifier)
            #expect(reopened.provider == codex)
            #expect(reopened.model == named)
            #expect(reopened.reasoningEffort == "high")
            #expect(first.model == reopened.model)
        }
    }

    @Test func choicesAreIsolatedByBackendAndPairingDoesNotPersist() throws {
        try withPersistence { persistence in
            _ = configuredSelection(persistence)
            let otherID = BackendID(UUID())
            let other = WorkspaceAgentSelection(backendID: otherID, persistence: persistence)
            reconcile(other)
            #expect(other.provider == auggie)
            #expect(other.specialist == implementor)
            #expect(other.model == nil)
            #expect(persistence.loadWorkspaceAgentPreferences(for: otherID) == nil)
            let pairing = WorkspaceAgentSelection(backendID: nil, persistence: persistence)
            pairing.selectProvider(codex)
            #expect(persistence.loadWorkspaceAgentPreferences(for: nil) == nil)
            #expect(persistence.loadWorkspaceAgentPreferences(for: backendID)?.providerID == "codex")
        }
    }

    @Test func explicitNoneDefaultAndAutoSurviveReopening() throws {
        try withPersistence { persistence in
            let selection = configuredSelection(persistence)
            selection.selectSpecialist(nil)
            selection.selectReasoning(nil)
            let reopened = WorkspaceAgentSelection(backendID: backendID, persistence: persistence)
            reconcile(reopened)
            #expect(reopened.specialist == nil)
            #expect(reopened.model == named)
            #expect(reopened.reasoningEffort == nil)
            reopened.selectModel(nil)
            let defaulted = WorkspaceAgentSelection(backendID: backendID, persistence: persistence)
            reconcile(defaulted)
            #expect(defaulted.specialist == nil)
            #expect(defaulted.provider == codex)
            #expect(defaulted.model == nil)
            #expect(defaulted.reasoningEffort == nil)
        }
    }

    @Test func temporaryCatalogClearsDoNotErasePendingChoices() throws {
        try withPersistence { persistence in
            _ = configuredSelection(persistence)
            let reopened = WorkspaceAgentSelection(backendID: backendID, persistence: persistence)
            reopened.reconcileProvider(state: .loading)
            reopened.reconcileSpecialist(catalog: [])
            reopened.reconcileModels([])
            reopened.selectSpecialist(implementor)
            reconcile(reopened)
            #expect(reopened.specialist == implementor)
            #expect(reopened.provider == codex)
            #expect(reopened.model == named)
            #expect(reopened.reasoningEffort == "high")
            #expect(persistence.loadWorkspaceAgentPreferences(for: backendID)?.modelID == named.id)
        }
    }

    @Test func providerPickedBeforeSpecialistsLoadKeepsTheNormalDefault() throws {
        try withPersistence { persistence in
            let selection = WorkspaceAgentSelection(backendID: backendID, persistence: persistence)
            selection.reconcileProvider(state: .loaded([auggie, codex]))
            selection.selectProvider(codex)
            selection.reconcileSpecialist(catalog: [implementor, verifier])
            #expect(selection.specialist == implementor)
            let reopened = WorkspaceAgentSelection(backendID: backendID, persistence: persistence)
            reconcile(reopened)
            #expect(reopened.specialist == implementor)
            #expect(reopened.provider == codex)
        }
    }

    @Test func unavailableProviderCannotReuseItsModelOnFallbackProvider() throws {
        try withPersistence { persistence in
            let selection = configuredSelection(persistence)
            selection.reconcileProvider(state: .loaded([auggie, ProviderInfo(id: "codex", authenticated: .signedOut)]))
            selection.reconcileModels([ModelInfo(id: named.id, name: "Other", provider: "auggie", effortLevels: ["high"])])
            #expect(selection.provider == auggie)
            #expect(selection.model == nil)
            #expect(selection.reasoningEffort == nil)
            reconcile(selection)
            #expect(selection.provider == codex)
            #expect(selection.model == named)
            #expect(selection.reasoningEffort == "high")
        }
    }

    @Test func explicitProviderSwitchClearsRememberedModelAndReasoning() throws {
        try withPersistence { persistence in
            let selection = configuredSelection(persistence)
            selection.selectProvider(auggie)
            let reopened = WorkspaceAgentSelection(backendID: backendID, persistence: persistence)
            reconcile(reopened)
            reopened.reconcileModels([ModelInfo(id: named.id, name: "Other", provider: "auggie")])
            #expect(reopened.provider == auggie)
            #expect(reopened.model == nil)
            #expect(reopened.reasoningEffort == nil)
        }
    }

    @Test func unavailableSpecialistsModelsAndEffortsFallBackSafely() throws {
        try withPersistence { persistence in
            let selection = configuredSelection(persistence)
            var hidden = verifier
            hidden.hidden = true
            selection.reconcileSpecialist(catalog: [implementor, hidden])
            #expect(selection.specialist == implementor)
            var refreshed = named
            refreshed.effortLevels = ["low"]
            selection.reconcileModels([refreshed])
            #expect(selection.model == refreshed)
            #expect(selection.reasoningEffort == nil)
            selection.reconcileModels([ModelInfo(id: "replacement", name: "Replacement", provider: "codex")])
            #expect(selection.model == nil)
            selection.reconcileProvider(state: .loaded([]))
            #expect(selection.provider == nil)
        }
    }

    @Test func malformedPreferencesUseNormalDefaults() throws {
        try withPersistence { persistence in
            persistence.defaults.set(Data("invalid".utf8), forKey: "workspaceAgentPreferences.\(backendID.connectionID.uuidString)")
            let selection = WorkspaceAgentSelection(backendID: backendID, persistence: persistence)
            reconcile(selection)
            #expect(selection.specialist == implementor)
            #expect(selection.provider == auggie)
            #expect(selection.model == nil)
        }
    }

    private func reconcile(_ selection: WorkspaceAgentSelection) {
        selection.reconcileSpecialist(catalog: [implementor, verifier])
        selection.reconcileProvider(state: .loaded([auggie, codex]))
        selection.reconcileModels([named])
    }

    private func configuredSelection(_ persistence: PersistenceManager) -> WorkspaceAgentSelection {
        let selection = WorkspaceAgentSelection(backendID: backendID, persistence: persistence)
        reconcile(selection)
        selection.selectSpecialist(verifier)
        selection.selectProvider(codex)
        selection.selectModel(named)
        selection.selectReasoning("high")
        return selection
    }

    private func withPersistence(_ body: (PersistenceManager) -> Void) throws {
        let suite = "WorkspaceAgentSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        body(PersistenceManager(defaults: defaults, keychainStorage: EphemeralKeychainStorage()))
    }
}

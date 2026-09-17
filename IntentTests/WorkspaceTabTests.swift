@testable import Intent
import Testing

struct WorkspaceTabTests {
    @Test func namedTabsRoundTripExistingPersistedValues() {
        #expect(WorkspaceTab(persistedValue: 0) == .agents)
        #expect(WorkspaceTab(persistedValue: 1) == .context)
        #expect(WorkspaceTab.agents.persistedValue == 0)
        #expect(WorkspaceTab.context.persistedValue == 1)
    }

    @Test func unsupportedPersistedValueRetainsExistingContextBehavior() {
        let tab = WorkspaceTab(persistedValue: 42)

        #expect(tab == .unsupportedPersistedValue(42))
        #expect(tab != .agents)
        #expect(tab != .context)
        #expect(tab.persistedValue == 42)
    }

    @Test func firstAppearanceWithoutSavedValueRetainsCurrentSelection() {
        let restored = WorkspaceTab.restored(persistedValue: nil, fallback: .context)

        #expect(restored == .context)
    }

    @Test func workspaceSwitchRestoresSavedSelectionOrAgentsFallback() {
        #expect(WorkspaceTab.restored(persistedValue: 1, fallback: .agents) == .context)
        #expect(WorkspaceTab.restored(persistedValue: 7, fallback: .agents)
            == .unsupportedPersistedValue(7))
        #expect(WorkspaceTab.restored(persistedValue: nil, fallback: .agents) == .agents)
    }
}

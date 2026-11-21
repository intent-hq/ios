@testable import Intent
import SwiftUI
import Testing

extension CreateWorkspaceParamsTests {
    // MARK: - pickerSpecialists (cached catalog → picker list)

    private func makeCatalogSpecialist(
        id: String,
        name: String,
        hidden: Bool = false,
        role: String? = nil
    ) -> SpecialistInfo {
        SpecialistInfo(id: id, name: name, description: "", hidden: hidden, role: role)
    }

    @Test func pickerSpecialistsDropsHiddenAndInternalAndPinsOrchestratorFirst() {
        let catalog = [
            makeCatalogSpecialist(id: "verifier", name: "Verifier"),
            makeCatalogSpecialist(id: "secret", name: "Aardvark", hidden: true),
            makeCatalogSpecialist(id: "helper", name: "Abacus", role: "internal"),
            makeCatalogSpecialist(id: "implementor", name: "Implementor"),
            makeCatalogSpecialist(id: "coordinator", name: "Zeta", role: "orchestrator")
        ]
        #expect(
            CreationSelectionPolicy.workspacePickerSpecialists(catalog).map(\.id)
                == ["coordinator", "implementor", "verifier"]
        )
        #expect(CreationSelectionPolicy.workspacePickerSpecialists([]).isEmpty)
    }

    // MARK: - preselectedSpecialist

    @Test func preselectedSpecialistDefaultsToOrchestratorElseFirst() {
        let withOrchestrator = [
            makeCatalogSpecialist(id: "coordinator", name: "Coordinator", role: "orchestrator"),
            makeCatalogSpecialist(id: "implementor", name: "Implementor")
        ]
        #expect(
            CreationSelectionPolicy.preselectedWorkspaceSpecialist(
                current: nil,
                catalog: withOrchestrator
            )?.id == "coordinator"
        )
        let plain = [
            makeCatalogSpecialist(id: "verifier", name: "Verifier"),
            makeCatalogSpecialist(id: "implementor", name: "Implementor")
        ]
        #expect(
            CreationSelectionPolicy.preselectedWorkspaceSpecialist(
                current: nil,
                catalog: plain
            )?.id == "implementor"
        )
    }

    @Test func preselectedSpecialistKeepsStillListedSelectionAndRedefaultsWhenGone() {
        let specialists = [
            makeCatalogSpecialist(id: "verifier", name: "Verifier"),
            makeCatalogSpecialist(id: "implementor", name: "Implementor")
        ]
        #expect(
            CreationSelectionPolicy.preselectedWorkspaceSpecialist(
                current: makeSpecialist(id: "verifier"),
                catalog: specialists
            )?.id == "verifier"
        )
        #expect(
            CreationSelectionPolicy.preselectedWorkspaceSpecialist(
                current: makeSpecialist(id: "retired"),
                catalog: specialists
            )?.id == "implementor"
        )
    }

    @Test func preselectedSpecialistRebindsSurvivingSelectionToFreshMetadata() {
        let stale = makeSpecialist(id: "implementor", resolvedModel: "sonnet4.5", resolvedProvider: "auggie")
        let refreshed = [
            makeSpecialist(id: "verifier"),
            makeSpecialist(id: "implementor", resolvedModel: "opus4.6", resolvedProvider: "auggie")
        ]
        let kept = CreationSelectionPolicy.preselectedWorkspaceSpecialist(current: stale, catalog: refreshed)
        #expect(kept?.id == "implementor")
        #expect(kept?.resolvedModel == "opus4.6")
        #expect(kept == refreshed[1])
    }

    @Test func preselectedSpecialistRedefaultsWhenSelectionTurnsHiddenUnderSameIds() {
        let selected = makeCatalogSpecialist(id: "implementor", name: "Implementor")
        let refreshed = [
            makeCatalogSpecialist(id: "coordinator", name: "Coordinator", role: "orchestrator"),
            makeCatalogSpecialist(id: "implementor", name: "Implementor", hidden: true)
        ]
        #expect(refreshed.map(\.id) == ["coordinator", "implementor"])
        #expect(
            CreationSelectionPolicy.preselectedWorkspaceSpecialist(
                current: selected,
                catalog: refreshed
            )?.id == "coordinator"
        )
        let internalised = [
            makeCatalogSpecialist(id: "coordinator", name: "Coordinator", role: "orchestrator"),
            makeCatalogSpecialist(id: "implementor", name: "Implementor", role: "internal")
        ]
        #expect(
            CreationSelectionPolicy.preselectedWorkspaceSpecialist(
                current: selected,
                catalog: internalised
            )?.id == "coordinator"
        )
    }

    @Test func preselectedSpecialistClearsWhenSolePickableSpecialistTurnsHidden() {
        let selected = makeCatalogSpecialist(id: "implementor", name: "Implementor")
        let hiddenOnly = [makeCatalogSpecialist(id: "implementor", name: "Implementor", hidden: true)]
        #expect(CreationSelectionPolicy.workspacePickerSpecialists(hiddenOnly).isEmpty)
        #expect(CreationSelectionPolicy.preselectedWorkspaceSpecialist(current: selected, catalog: hiddenOnly) == nil)
        let internalOnly = [makeCatalogSpecialist(id: "implementor", name: "Implementor", role: "internal")]
        #expect(CreationSelectionPolicy.preselectedWorkspaceSpecialist(current: selected, catalog: internalOnly) == nil)
        #expect(CreationSelectionPolicy.preselectedWorkspaceSpecialist(current: nil, catalog: hiddenOnly) == nil)
    }

    @Test func specialistCatalogEqualityTracksMetadataNotJustIds() {
        let base = makeCatalogSpecialist(id: "implementor", name: "Implementor")
        #expect([base] == [makeCatalogSpecialist(id: "implementor", name: "Implementor")])
        #expect([base] != [makeCatalogSpecialist(id: "implementor", name: "Implementor", hidden: true)])
        #expect([base] != [makeCatalogSpecialist(id: "implementor", name: "Implementor", role: "internal")])
        #expect([base] != [makeSpecialist(id: "implementor", resolvedModel: "opus4.6", resolvedProvider: "auggie")])
    }

    @Test func preselectedSpecialistKeepsSelectionAcrossAnEmptyCatalog() {
        #expect(
            CreationSelectionPolicy.preselectedWorkspaceSpecialist(
                current: makeSpecialist(id: "implementor"),
                catalog: []
            )?.id == "implementor"
        )
        #expect(CreationSelectionPolicy.preselectedWorkspaceSpecialist(current: nil, catalog: []) == nil)
    }

    // MARK: - showsOptionsLoading (cached reopen never spins; warm-before-load clears)

    @Test func showsOptionsLoadingOnlyWhileColdOrStoreLoading() {
        #expect(
            CreateWorkspaceView.showsOptionsLoading(
                storeIsLoading: false,
                storeHasLoaded: false,
                settled: false
            )
        )
        #expect(
            CreateWorkspaceView.showsOptionsLoading(
                storeIsLoading: true,
                storeHasLoaded: false,
                settled: false
            )
        )
        #expect(
            !CreateWorkspaceView.showsOptionsLoading(
                storeIsLoading: false,
                storeHasLoaded: true,
                settled: false
            )
        )
        #expect(
            !CreateWorkspaceView.showsOptionsLoading(
                storeIsLoading: false,
                storeHasLoaded: true,
                settled: true
            )
        )
        #expect(
            !CreateWorkspaceView.showsOptionsLoading(
                storeIsLoading: false,
                storeHasLoaded: false,
                settled: true
            )
        )
        #expect(
            CreateWorkspaceView.showsOptionsLoading(
                storeIsLoading: true,
                storeHasLoaded: false,
                settled: true
            )
        )
    }

    @Test func showsOptionsLoadingClearsWhenCacheWarmsBetweenConstructionAndLoad() {
        #expect(
            CreateWorkspaceView.showsOptionsLoading(
                storeIsLoading: false,
                storeHasLoaded: false,
                settled: false
            )
        )
        #expect(
            !CreateWorkspaceView.showsOptionsLoading(
                storeIsLoading: false,
                storeHasLoaded: true,
                settled: false
            )
        )
    }

    // MARK: - showsModelCatalogLoading (Create waits for the first catalog; warm catalog is instant)

    @Test func modelCatalogLoadingGatesCreateUntilFirstCatalogSettles() {
        #expect(CreateWorkspaceView.showsModelCatalogLoading(catalogCached: false, settled: false))
        #expect(!CreateWorkspaceView.showsModelCatalogLoading(catalogCached: true, settled: false))
        #expect(!CreateWorkspaceView.showsModelCatalogLoading(catalogCached: true, settled: true))
        #expect(!CreateWorkspaceView.showsModelCatalogLoading(catalogCached: nil, settled: false))
        #expect(!CreateWorkspaceView.showsModelCatalogLoading(catalogCached: false, settled: true))
    }

    @Test func createDisabledWhileFirstModelCatalogResolves() {
        let catalogLoading = CreateWorkspaceView.showsModelCatalogLoading(
            catalogCached: false,
            settled: false
        )
        #expect(isCreateDisabled(providers: [makeProvider()], isLoadingProviders: catalogLoading))
        let catalogWarm = CreateWorkspaceView.showsModelCatalogLoading(
            catalogCached: true,
            settled: false
        )
        #expect(!isCreateDisabled(providers: [makeProvider()], isLoadingProviders: catalogWarm))
    }
}

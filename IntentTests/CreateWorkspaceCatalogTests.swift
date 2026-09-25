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
        // A background refresh dropped the selected specialist: re-default
        // to the first pickable entry (name order).
        #expect(
            CreationSelectionPolicy.preselectedWorkspaceSpecialist(
                current: makeSpecialist(id: "retired"),
                catalog: specialists
            )?.id == "implementor"
        )
    }

    @Test func preselectedSpecialistRebindsSurvivingSelectionToFreshMetadata() {
        // A background refresh returns the same ids with a new default-model
        // preview: the selection must carry the fresh DTO, not the stale one.
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
        // Identical catalog ids, but the selected specialist flipped to
        // hidden: it leaves the picker list, so the selection re-defaults.
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
        // The same catalog with the role flipped to internal behaves alike.
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
        // The selected specialist was the only pickable one; a background
        // refresh marks it hidden. The catalog is authoritative (non-empty)
        // yet lists nothing pickable, so the selection clears rather than
        // letting a hidden id reach buildCreateWorkspaceParams.
        let selected = makeCatalogSpecialist(id: "implementor", name: "Implementor")
        let hiddenOnly = [makeCatalogSpecialist(id: "implementor", name: "Implementor", hidden: true)]
        #expect(CreationSelectionPolicy.workspacePickerSpecialists(hiddenOnly).isEmpty)
        #expect(CreationSelectionPolicy.preselectedWorkspaceSpecialist(current: selected, catalog: hiddenOnly) == nil)
        let internalOnly = [makeCatalogSpecialist(id: "implementor", name: "Implementor", role: "internal")]
        #expect(CreationSelectionPolicy.preselectedWorkspaceSpecialist(current: selected, catalog: internalOnly) == nil)
        #expect(CreationSelectionPolicy.preselectedWorkspaceSpecialist(current: nil, catalog: hiddenOnly) == nil)
    }

    @Test func specialistCatalogEqualityTracksMetadataNotJustIds() {
        // The view observes the cached catalog by value: a same-id change in
        // hidden / role / default preview must compare unequal so the
        // observer fires and reconciliation runs.
        let base = makeCatalogSpecialist(id: "implementor", name: "Implementor")
        #expect([base] == [makeCatalogSpecialist(id: "implementor", name: "Implementor")])
        #expect([base] != [makeCatalogSpecialist(id: "implementor", name: "Implementor", hidden: true)])
        #expect([base] != [makeCatalogSpecialist(id: "implementor", name: "Implementor", role: "internal")])
        #expect([base] != [makeSpecialist(id: "implementor", resolvedModel: "opus4.6", resolvedProvider: "auggie")])
    }

    @Test func preselectedSpecialistKeepsSelectionAcrossAnEmptyCatalog() {
        // A reconnect clears the cache before reloading it: the selection
        // survives the empty interim (and nil stays nil). Only an empty
        // catalog is transient — a non-empty one is authoritative.
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
        // Cold cache, sheet's load not yet settled: loading.
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
        // Warm cache (cached reopen): never loading, even during an SWR
        // revalidation, which the store runs without touching isLoading.
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
        // A settled cold load that failed shows the empty state, not a spinner.
        #expect(
            !CreateWorkspaceView.showsOptionsLoading(
                storeIsLoading: false,
                storeHasLoaded: false,
                settled: true
            )
        )
        // A reconnect hard-clear reloads cold: loading drives back on.
        #expect(
            CreateWorkspaceView.showsOptionsLoading(
                storeIsLoading: true,
                storeHasLoaded: false,
                settled: true
            )
        )
    }

    @Test func showsOptionsLoadingClearsWhenCacheWarmsBetweenConstructionAndLoad() {
        // The sheet was constructed over a cold cache (loading), then another
        // sheet / the reconnect reload warmed the shared store before this
        // sheet's specialist step ran its load: the state is derived from
        // the store, so it clears without the sheet's own load settling.
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
        // Selected provider, catalog not cached, sheet's first load not
        // settled: the catalog is still resolving, Create stays disabled.
        #expect(CreateWorkspaceView.showsModelCatalogLoading(catalogCached: false, settled: false))
        // Warm catalog (cached reopen / provider already loaded): instant.
        #expect(!CreateWorkspaceView.showsModelCatalogLoading(catalogCached: true, settled: false))
        #expect(!CreateWorkspaceView.showsModelCatalogLoading(catalogCached: true, settled: true))
        // No selected provider: nothing to wait on.
        #expect(!CreateWorkspaceView.showsModelCatalogLoading(catalogCached: nil, settled: false))
        // Settled with the catalog still missing (the load failed): the
        // daemon default applies, not an indefinite gate.
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

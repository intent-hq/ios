import Foundation
@testable import Intent
import Testing

@MainActor
extension CreationOptionsStoreTests {
    // MARK: - Models (per provider)

    @Test func coldModelLoadFetchesAndCachesPerProvider() async {
        let (store, fake) = await makeLoadedStore()
        #expect(store.models(for: "auggie") == nil)

        await store.loadModelsIfNeeded(providerId: "auggie")

        let calls = fake.paramsForMethod("models.list")
        #expect(calls.count == 1)
        #expect(calls[0]["providerId"] as? String == "auggie")
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        #expect(store.models(for: "auggie")?.first?.provider == "auggie")
        #expect(store.models(for: "codex") == nil)
        #expect(store.isLoading == false)
    }

    @Test func modelParsingFallsBackToRequestedProviderAndSkipsUnparsableRows() async {
        let (store, fake) = await makeLoadedStore()
        fake.responseMap["models.list"] = [
            "models": [
                ["id": "gpt-5", "name": "GPT-5"],
                [
                    "id": "gpt-5-mini", "name": "GPT-5 mini", "provider": "codex", "isDefault": true,
                    "effortLevels": ["low", "high", "future-level"]
                ],
                ["id": "malformed", "name": "Malformed metadata", "effortLevels": "high"],
                ["id": "mixed", "name": "Mixed metadata", "effortLevels": ["high", 3]],
                ["id": "no-name"]
            ]
        ]

        await store.loadModelsIfNeeded(providerId: "codex")

        let models = store.models(for: "codex") ?? []
        #expect(models.map(\.id) == ["gpt-5", "gpt-5-mini", "malformed", "mixed"])
        #expect(models.map(\.provider) == ["codex", "codex", "codex", "codex"])
        #expect(models.map(\.isDefault) == [false, true, false, false])
        #expect(models.map(\.effortLevels) == [[], ["low", "high", "future-level"], [], []])
    }

    @Test func cachedModelLoadReturnsImmediatelyAndRevalidatesSilently() async throws {
        let (store, fake) = await makeLoadedStore()
        await store.loadModelsIfNeeded(providerId: "auggie")
        fake.pendingMethods = ["models.list"]

        await store.loadModelsIfNeeded(providerId: "auggie")

        try await waitFor("refresh read") { fake.paramsForMethod("models.list").count == 2 }
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        #expect(store.isLoading == false)

        fake.resolvePending("models.list", with: ["models": [modelDict(id: "opus4.6")]])
        try await waitFor("refresh completion") { store.models(for: "auggie")?.map(\.id) == ["opus4.6"] }
    }

    @Test func concurrentModelLoadsForOneProviderShareOneFlight() async throws {
        let (store, fake) = await makeLoadedStore()
        fake.pendingMethods = ["models.list"]
        let first = Task { await store.loadModelsIfNeeded(providerId: "auggie") }
        let second = Task { await store.loadModelsIfNeeded(providerId: "auggie") }
        let other = Task { await store.loadModelsIfNeeded(providerId: "codex") }
        try await waitFor("both cold reads") { fake.paramsForMethod("models.list").count == 2 }
        fake.resolvePending("models.list", with: ["models": [modelDict(id: "sonnet4.5")]])
        fake.resolvePending("models.list", with: ["models": [modelDict(id: "gpt", provider: "codex")]])
        _ = await (first.value, second.value, other.value)

        let providerIds = fake.paramsForMethod("models.list").compactMap { $0["providerId"] as? String }
        #expect(providerIds.sorted() == ["auggie", "codex"])
        #expect(store.models(for: "auggie") != nil)
        #expect(store.models(for: "codex") != nil)
    }

    @Test func failedModelLoadKeepsCacheAndRetriesColdNextTime() async throws {
        let (store, fake) = await makeLoadedStore()
        fake.errorMap["models.list"] = NSError(domain: "t", code: -1)

        await store.loadModelsIfNeeded(providerId: "auggie")
        #expect(store.models(for: "auggie") == nil)

        fake.errorMap["models.list"] = nil
        await store.loadModelsIfNeeded(providerId: "auggie")
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        #expect(fake.paramsForMethod("models.list").count == 2)

        fake.errorMap["models.list"] = NSError(domain: "t", code: -1)
        await store.loadModelsIfNeeded(providerId: "auggie")
        try await waitFor("refresh read") { fake.paramsForMethod("models.list").count == 3 }
        try await waitFor("failed refresh to settle") { store.modelCatalog(for: "auggie").loadFailed }
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
    }

    @Test func invalidateDuringPendingModelLoadRejectsStaleCompletion() async throws {
        let (store, fake) = await makeLoadedStore()
        fake.pendingMethods = ["models.list"]
        let load = Task { await store.loadModelsIfNeeded(providerId: "auggie") }
        try await waitFor("model read") { fake.didCallMethod("models.list") }

        store.invalidate()
        fake.resolvePending("models.list", with: ["models": [modelDict(id: "stale")]])
        await load.value
        #expect(store.models(for: "auggie") == nil)

        fake.pendingMethods = []
        await store.loadModelsIfNeeded(providerId: "auggie")
        #expect(store.models(for: "auggie")?.map(\.id) == ["sonnet4.5"])
        #expect(fake.paramsForMethod("models.list").count == 2)
    }
}

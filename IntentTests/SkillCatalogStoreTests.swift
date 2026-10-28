import Foundation
@testable import Intent
import Testing

@MainActor
struct SkillCatalogStoreTests {
    private func skill(_ name: String, location: String? = nil) -> [String: Any] {
        ["name": name, "description": "Use \(name)", "location": location ?? "/skills/\(name)/SKILL.md", "scope": "user"]
    }

    @Test func loadsBareArrayDeduplicatesLocationsAndSortsDeterministically() async {
        let fake = FakeConnectionManager()
        var project = skill("Alpha", location: "/project/SKILL.md")
        project["scope"] = "project"
        project["resourceDirectory"] = "/project"
        fake.responseMap["skill.list"] = [
            skill("zulu"), skill("alpha"), skill("Alpha", location: "/user/SKILL.md"), project,
            skill("duplicate", location: "/project/SKILL.md")
        ]
        let store = SkillCatalogStore()

        await store.load(workspaceId: "workspace", connection: fake)

        #expect(store.skills.map(\.name) == ["Alpha", "Alpha", "alpha", "zulu"])
        #expect(store.skills.first == SkillInfo(
            name: "Alpha",
            description: "Use Alpha",
            location: "/project/SKILL.md",
            scope: "project",
            resourceDirectory: "/project"
        ))
        #expect(store.skills[1].resourceDirectory == nil)
        #expect(store.skills.map(\.id) == store.skills.map(\.location))
        #expect(fake.paramsForMethod("skill.list").count == 1)
        #expect(fake.paramsForMethod("skill.list").first?["workspaceId"] as? String == "workspace")
        #expect(!store.isLoading && store.errorMessage == nil)
    }

    @Test func skipsMalformedRowsWithoutLosingValidSkills() async {
        let fake = FakeConnectionManager()
        var missingDescription = skill("missing")
        missingDescription.removeValue(forKey: "description")
        var invalidOptional = skill("valid")
        invalidOptional["resourceDirectory"] = 42
        fake.responseMap["skill.list"] = [
            "invalid", NSNull(), missingDescription, skill(" "), skill("blank-location", location: "\n"),
            ["name": "wrong", "description": "", "location": "/wrong", "scope": 3], invalidOptional
        ] as [Any]
        let store = SkillCatalogStore()

        await store.load(workspaceId: "workspace", connection: fake)

        #expect(store.skills.map(\.name) == ["valid"])
        #expect(store.skills.first?.resourceDirectory == nil)
        #expect(store.errorMessage == nil)
    }

    @Test func rejectsEnvelopeAndRetriesFailures() async {
        let fake = FakeConnectionManager()
        let store = SkillCatalogStore()
        fake.responseMap["skill.list"] = ["skills": [skill("wrong-envelope")]]
        await store.load(workspaceId: "workspace", connection: fake)
        #expect(store.skills.isEmpty && store.errorMessage != nil && !store.isLoading)

        fake.errorMap["skill.list"] = URLError(.notConnectedToInternet)
        await store.load(workspaceId: "workspace", connection: fake)
        #expect(store.skills.isEmpty && store.errorMessage != nil && !store.isLoading)

        fake.errorMap.removeValue(forKey: "skill.list")
        fake.responseMap["skill.list"] = [skill("recovered")]
        await store.load(workspaceId: "workspace", connection: fake)
        #expect(store.skills.map(\.name) == ["recovered"])
        #expect(store.errorMessage == nil && !store.isLoading)
        #expect(fake.paramsForMethod("skill.list").count == 3)
    }

    @Test func refreshesSuccessfulCatalogAndAcceptsEmptyList() async {
        let fake = FakeConnectionManager()
        fake.responseQueueMap["skill.list"] = [[skill("old")], [skill("new")], [] as [Any]]
        let store = SkillCatalogStore()

        await store.load(workspaceId: "workspace", connection: fake)
        #expect(store.skills.map(\.name) == ["old"])
        await store.load(workspaceId: "workspace", connection: fake)
        #expect(store.skills.map(\.name) == ["new"])
        await store.load(workspaceId: "workspace", connection: fake)
        #expect(store.skills.isEmpty && store.errorMessage == nil && !store.isLoading)
        #expect(fake.paramsForMethod("skill.list").count == 3)
    }

    @Test func workspaceChangeClearsPriorSkillsBeforeResponse() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["skill.list"] = [skill("previous")]
        let store = SkillCatalogStore()
        await store.load(workspaceId: "previous", connection: fake)
        fake.pendingMethods = ["skill.list"]
        let loading = Task { await store.load(workspaceId: "next", connection: fake) }
        defer { loading.cancel() }
        try await fake.waitForPendingRequests("skill.list")
        #expect(store.skills.isEmpty && store.isLoading && store.errorMessage == nil)

        fake.failPending("skill.list", with: URLError(.notConnectedToInternet))
        await loading.value
        #expect(store.skills.isEmpty && !store.isLoading && store.errorMessage != nil)
    }

    @Test(arguments: [false, true])
    func supersededReplyCannotReplaceNewerCatalog(fails: Bool) async throws {
        let oldConnection = FakeConnectionManager()
        oldConnection.pendingMethods = ["skill.list"]
        let newConnection = FakeConnectionManager()
        newConnection.responseMap["skill.list"] = [skill("current")]
        let store = SkillCatalogStore()
        let oldLoad = Task { await store.load(workspaceId: "old", connection: oldConnection) }
        defer { oldLoad.cancel() }
        try await oldConnection.waitForPendingRequests("skill.list")
        await store.load(workspaceId: "new", connection: newConnection)

        if fails {
            oldConnection.failPending("skill.list", with: URLError(.notConnectedToInternet))
        } else {
            oldConnection.resolvePending("skill.list", with: [skill("stale")])
        }
        await oldLoad.value
        #expect(store.skills.map(\.name) == ["current"])
        #expect(!store.isLoading && store.errorMessage == nil)
    }

    @Test func olderCompletionDoesNotEndNewerLoadingState() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods = ["skill.list"]
        let store = SkillCatalogStore()
        let first = Task { await store.load(workspaceId: "workspace", connection: fake) }
        defer { first.cancel() }
        try await fake.waitForPendingRequests("skill.list")
        let second = Task { await store.load(workspaceId: "workspace", connection: fake) }
        defer { second.cancel() }
        try await fake.waitForPendingRequests("skill.list", count: 2)

        fake.resolvePending("skill.list", with: [skill("stale")])
        await first.value
        #expect(store.isLoading && store.skills.isEmpty && store.errorMessage == nil)
        fake.resolvePending("skill.list", with: [skill("current")])
        await second.value
        #expect(!store.isLoading && store.skills.map(\.name) == ["current"])
    }

    @Test func cancellationIsSilentAndNextLoadCanRetry() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods = ["skill.list"]
        let store = SkillCatalogStore()
        let loading = Task { await store.load(workspaceId: "workspace", connection: fake) }
        defer { loading.cancel() }
        try await fake.waitForPendingRequests("skill.list")
        loading.cancel()
        await loading.value
        #expect(store.skills.isEmpty && !store.isLoading && store.errorMessage == nil)

        fake.pendingMethods = []
        fake.responseMap["skill.list"] = [skill("retry")]
        await store.load(workspaceId: "workspace", connection: fake)
        #expect(store.skills.map(\.name) == ["retry"])
    }

    @Test func resetDiscardsPendingReplies() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods = ["skill.list"]
        let store = SkillCatalogStore()
        let loading = Task { await store.load(workspaceId: "workspace", connection: fake) }
        defer { loading.cancel() }
        try await fake.waitForPendingRequests("skill.list")
        store.reset()
        #expect(!store.isLoading && store.skills.isEmpty && store.errorMessage == nil)
        fake.resolvePending("skill.list", with: [skill("stale")])
        await loading.value
        #expect(!store.isLoading && store.skills.isEmpty && store.errorMessage == nil)
    }
}

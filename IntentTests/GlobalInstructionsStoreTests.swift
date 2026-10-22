import Foundation
@testable import Intent
import Testing

@MainActor
struct GlobalInstructionsStoreTests {
    private func connection() -> RPCRecordingConnection {
        let fake = RPCRecordingConnection()
        fake.responseMap["rules.get"] = ["content": "Existing instructions", "enabled": true, "updatedAt": 0]
        fake.responseMap["rules.update"] = ["rules": ["rules": []]]
        return fake
    }

    @Test func savesGlobalOverrideAndKeepsDisabledContent() async {
        let fake = connection()
        let store = GlobalInstructionsStore(connection: fake)
        await store.load()
        #expect(store.content == "Existing instructions")
        #expect(store.enabled)
        #expect(!store.hasChanges)
        store.content = "  Keep this formatting.\n"
        store.enabled = false
        await store.save()
        let params = fake.paramsForMethod("rules.update").first
        #expect(params?["workspaceId"] as? String == "global")
        #expect(params?["ruleType"] as? String == "base-system-prompt")
        #expect(params?["content"] as? String == "  Keep this formatting.\n")
        #expect(params?["enabled"] as? Bool == false)
        #expect(!store.hasChanges)
        #expect(store.errorMessage == nil)
        await store.save()
        #expect(fake.paramsForMethod("rules.update").count == 1)
    }

    @Test func failedSaveRetainsDraftAndCanRetry() async {
        let fake = connection()
        let store = GlobalInstructionsStore(connection: fake)
        await store.load()
        store.content = "My unsaved instructions"
        fake.errorMap["rules.update"] = NSError(domain: "test", code: -1)
        await store.save()
        #expect(store.content == "My unsaved instructions")
        #expect(store.hasChanges)
        #expect(store.errorMessage != nil)
        #expect(!store.isSaving)
        await store.load()
        #expect(store.content == "My unsaved instructions")
        fake.errorMap["rules.update"] = nil
        await store.save()
        #expect(!store.hasChanges)
        #expect(store.errorMessage == nil)
    }

    @Test func malformedReadCannotOverwriteHostAndCanRetry() async {
        let fake = connection()
        fake.responseMap["rules.get"] = ["content": "Missing enabled state"]
        let store = GlobalInstructionsStore(connection: fake)
        await store.load()
        #expect(!store.isLoaded)
        #expect(store.errorMessage != nil)
        store.content = "Must not overwrite unread instructions"
        await store.save()
        #expect(fake.paramsForMethod("rules.update").isEmpty)
        fake.responseMap["rules.get"] = ["content": "Loaded on retry", "enabled": false]
        await store.load()
        #expect(store.isLoaded)
        #expect(store.content == "Loaded on retry")
        #expect(store.errorMessage == nil)
    }

    @Test func editsDuringSaveRemainUnsavedAndDuplicateSaveIsIgnored() async throws {
        let fake = connection()
        let store = GlobalInstructionsStore(connection: fake)
        await store.load()
        store.content = "Submitted"
        fake.pendingMethods = ["rules.update"]
        let save = Task { await store.save() }
        try await fake.waitForPendingRequests("rules.update")
        store.content = "Newer draft"
        await store.save()
        #expect(fake.paramsForMethod("rules.update").count == 1)
        fake.resolvePending("rules.update", with: ["rules": ["rules": []]])
        await save.value
        #expect(store.content == "Newer draft")
        #expect(store.hasChanges)
    }
}

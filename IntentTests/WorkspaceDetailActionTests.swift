#if DEBUG
import Foundation
@testable import Intent
import SwiftUI
import Testing
import UIKit

/// Archive and delete from the workspace page go through the workspace store: success leaves
/// for the list, failure keeps the page and shows the server's message.
@MainActor
@Suite(.serialized)
struct WorkspaceDetailActionTests {
    @Test(arguments: [WorkspaceAction.archive, .delete])
    func successRemovesTheRowAndLeavesBeforeTheListRefresh(_ action: WorkspaceAction) async throws {
        let (fake, store) = try Self.fixture()
        fake.responseMap[action.method] = Self.successResponse(action)
        fake.responseMap["workspace.list"] = ["workspaces": [["id": "other", "title": "Other"]]]
        let presentation = WorkspaceDetailPresentation()
        var leftWithListRequests: [Int] = []

        await presentation.perform(action, workspaceId: "selected", store: store) {
            leftWithListRequests.append(fake.paramsForMethod("workspace.list").count)
        }

        #expect(leftWithListRequests == [0])
        #expect(fake.paramsForMethod(action.method).first?["workspaceId"] as? String == "selected")
        #expect(store.workspaces.map(\.id) == ["other"])
        #expect(presentation.actionError == nil)
    }

    @Test(arguments: [WorkspaceAction.archive, .delete])
    func failureKeepsTheWorkspaceAndRecordsTheMessage(_ action: WorkspaceAction) async throws {
        let (fake, store) = try Self.fixture()
        fake.errorMap[action.method] = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disconnected"])
        let presentation = WorkspaceDetailPresentation()
        var leaves = 0

        await presentation.perform(action, workspaceId: "selected", store: store) { leaves += 1 }

        #expect(leaves == 0)
        #expect(presentation.actionError == "Disconnected")
        #expect(store.workspaces.map(\.id) == ["selected", "other"])

        fake.responseMap[action.method] = ["success": false]
        fake.errorMap.removeAll()
        presentation.actionError = nil
        await presentation.perform(action, workspaceId: "selected", store: store) { leaves += 1 }
        #expect(leaves == 0)
        #expect(presentation.actionError == "The server did not confirm the workspace \(action.rawValue). Please try again.")
        #expect(store.workspaces.map(\.id) == ["selected", "other"])
    }

    /// Confirming in the page's own dialog runs the action: success returns to the list, and a
    /// failure shows "Workspace action failed" with the message while the page stays open.
    /// The test reads the presented confirmation but does not tap its buttons: activating
    /// actions inside a `UIAlertController` depends on the simulator (it fails on fresh CI
    /// simulators). It dismisses the dialog and runs the same `perform` call the page's
    /// confirm button makes, leaving through the coordinator as the page does.
    @Test(arguments: [WorkspaceAction.archive, .delete], [false, true])
    func confirmedActionFromThePage(_ action: WorkspaceAction, succeeds: Bool) async throws {
        let (fake, store) = try Self.fixture()
        if succeeds {
            fake.responseMap[action.method] = Self.successResponse(action)
            fake.responseMap["workspace.list"] = ["workspaces": [["id": "other", "title": "Other"]]]
        } else {
            fake.errorMap[action.method] = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disconnected"])
        }
        let host = Host(connection: fake, store: store)
        defer { host.tearDown() }
        let page = NavigationStack { host.view }.environment(host.coordinator).environment(host.session)

        try await SyntheticBadgeHost.render(page, width: 402, height: 874) { _, window in
            let presentation = host.view.presentation
            Self.setConfirmation(for: action, presented: true, on: presentation)
            let confirmation = try await Self.presentedAlert(titled: action.title, in: window)
            #expect(confirmation.actions.contains { $0.title == action.label })

            Self.setConfirmation(for: action, presented: false, on: presentation)
            try await waitUntil("the \"\(action.title)\" alert is dismissed", timeout: .seconds(5)) {
                window.rootViewController?.presentedViewController == nil
            }
            await presentation.perform(action, workspaceId: "selected", store: store) { host.coordinator.onBackToWorkspaceList() }

            if succeeds {
                try await waitUntil("the page returns to the workspace list", timeout: .seconds(5)) {
                    if case .workspaceList = host.coordinator.currentScreen { return true }
                    return false
                }
                #expect(presentation.actionError == nil)
                #expect(!store.workspaces.contains { $0.id == "selected" })
            } else {
                let failure = try await Self.presentedAlert(titled: "Workspace action failed", in: window)
                #expect(failure.message == "Disconnected")
                #expect(presentation.actionError == "Disconnected")
                guard case let .workspaceDetail(workspaceId) = host.coordinator.currentScreen else {
                    Issue.record("The page left after a failed \(action.rawValue): \(host.coordinator.currentScreenDescription)")
                    return
                }
                #expect(workspaceId == "selected")
                #expect(store.workspaces.contains { $0.id == "selected" })
                await failure.dismiss(animated: false)
            }
        }
    }

    private static func setConfirmation(for action: WorkspaceAction, presented: Bool, on presentation: WorkspaceDetailPresentation) {
        if action == .archive {
            presentation.showArchiveConfirmation = presented
        } else {
            presentation.showDeleteConfirmation = presented
        }
    }

    private static func presentedAlert(titled title: String, in window: UIWindow) async throws -> UIAlertController {
        func alert() -> UIAlertController? {
            var controller = window.rootViewController?.presentedViewController
            while let current = controller {
                if let alert = current as? UIAlertController, alert.title == title { return alert }
                controller = current.presentedViewController
            }
            return nil
        }
        try await waitUntil("the \"\(title)\" alert is presented", timeout: .seconds(5)) { alert() != nil }
        return try #require(alert())
    }

    private static func fixture() throws -> (FakeConnectionManager, WorkspaceStore) {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        store.workspaces = try ["selected", "other"].map { id in
            try #require(WorkspaceStore.parseWorkspace(["id": id, "title": id]))
        }
        return (fake, store)
    }

    private static func successResponse(_ action: WorkspaceAction) -> [String: Any] {
        action == .delete ? ["success": true] : ["workspace": ["id": "selected", "status": "Archived"]]
    }

    @MainActor
    private final class Host {
        let suiteName = "WorkspaceDetailActionTests.\(UUID().uuidString)"
        let session: BackendSession
        let coordinator: AppCoordinator
        let view: WorkspaceDetailView

        init(connection: FakeConnectionManager, store: WorkspaceStore) {
            _ = TestKeychainStorage.installed
            let fileLoader = WorkspaceFileImageLoader(connection: connection)
            session = BackendSession(
                backendID: BackendID(UUID()),
                connection: connection,
                workspaceStore: store,
                coordinatorFactory: { _ in fatalError("coordinator is not built in these tests") },
                githubRepoStore: GitHubRepoStore(connectionManager: connection),
                creationOptionsStore: CreationOptionsStore(connectionManager: connection),
                prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
                attachmentUploadService: AttachmentUploadService(connection: connection),
                workspaceFileImageLoader: fileLoader,
                attachmentImageLoader: AttachmentImageLoader(connection: connection, fileLoader: fileLoader),
                attentionCueCenter: WorkspaceAttentionCueCenter {}
            )
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            coordinator = AppCoordinator(
                workspaceStore: store,
                connection: connection,
                persistence: PersistenceManager(defaults: defaults, keychainStorage: InMemoryKeychainStorage())
            )
            coordinator.currentScreen = .workspaceDetail(workspaceId: "selected")
            view = WorkspaceDetailView(workspaceId: "selected", session: session)
        }

        func tearDown() {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
    }
}
#endif

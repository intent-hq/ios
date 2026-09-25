@testable import Intent
import Observation
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct WindowSceneTitleTests {
    @Test func anchorPublishesUpdatesClearsAndReattachesToItsWindow() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalTitle = scene.title
        let source = UIWindow(windowScene: scene)
        let anchor = WindowSceneTitle.TitleView()
        defer {
            anchor.detach()
            anchor.removeFromSuperview()
            scene.title = originalTitle
        }
        anchor.title = "First server"
        source.addSubview(anchor)
        #expect(anchor.window === source)
        #expect(scene.title == "First server")
        anchor.title = "Renamed server"
        #expect(scene.title == "Renamed server")

        anchor.removeFromSuperview()
        #expect(scene.title == "Renamed server", "Temporary detachment preserves the last published title")
        anchor.title = "Second server"
        #expect(scene.title == "Renamed server", "An unattached anchor must not write to a remembered scene")
        source.addSubview(anchor)
        #expect(scene.title == "Second server")
        anchor.title = nil
        #expect(scene.title?.isEmpty == true, "Home clears the previous server label")
        anchor.title = "Restored server"
        #expect(scene.title == "Restored server")
        WindowSceneTitle.dismantleUIView(anchor, coordinator: ())
        #expect(scene.title?.isEmpty == true)
        anchor.title = "Retired update"
        #expect(scene.title?.isEmpty == true, "Dismantling retires the old scene attachment")
    }

    @Test func navigationTitleWritesCannotReplaceTheAssignedServer() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalTitle = scene.title
        let source = UIWindow(windowScene: scene)
        let anchor = WindowSceneTitle.TitleView()
        defer {
            anchor.detach()
            anchor.removeFromSuperview()
            scene.title = originalTitle
        }
        anchor.title = "Studio"
        source.addSubview(anchor)
        for title in ["Workspaces", "Conversation", "Settings"] {
            scene.title = title
            try await waitUntil("the server label to supersede the navigation title") { scene.title == "Studio" }
        }
        // A queued notification from an old navigation write must not bring
        // back the old server after Home or a rebind.
        scene.title = "Old navigation"
        anchor.title = nil
        await Task.yield()
        #expect(scene.title?.isEmpty == true)
        anchor.title = "New server"
        scene.title = "Settings"
        try await waitUntil("a rebind to supersede a stale navigation write") { scene.title == "New server" }
        anchor.detach()
        scene.title = "Unowned scene"
        await Task.yield()
        #expect(scene.title == "Unowned scene")
    }

    @Test func hostedSwiftUIBridgeFollowsNameChangesAndNavigation() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalTitle = scene.title
        let previousKey = scene.keyWindow
        let source = UIWindow(windowScene: scene)
        let state = NavigationState()
        let host = UIHostingController(rootView: NavigationFixture(state: state))
        source.rootViewController = host
        source.makeKeyAndVisible()
        defer {
            source.isHidden = true
            source.rootViewController = nil
            previousKey?.makeKey()
            scene.title = originalTitle
        }
        try await waitUntil("SwiftUI to mount the scene label") { scene.title == "Studio" }
        state.path = ["Conversation"]
        try await waitUntil("the conversation destination to appear") { state.appearedScreen == "Conversation" }
        try await waitUntil("the server label to survive conversation navigation") { scene.title == "Studio" }
        state.title = "Renamed studio"
        try await waitUntil("SwiftUI to publish a saved-name change") { scene.title == "Renamed studio" }
        state.path = ["Settings"]
        try await waitUntil("the settings destination to appear") { state.appearedScreen == "Settings" }
        try await waitUntil("the server label to survive settings navigation") { scene.title == "Renamed studio" }
        state.title = nil
        try await waitUntil("SwiftUI to clear the label at Home") { scene.title?.isEmpty == true }
    }

    @Observable final class NavigationState {
        var title: String? = "Studio"
        var path: [String] = []
        var appearedScreen: String?
    }

    private struct NavigationFixture: View {
        @Bindable var state: NavigationState

        var body: some View {
            NavigationStack(path: $state.path) {
                Text("Workspaces")
                    .navigationTitle("Workspaces")
                    .navigationDestination(for: String.self) { screen in
                        Text(screen)
                            .navigationTitle(screen)
                            .onAppear { state.appearedScreen = screen }
                    }
            }
            .background(WindowSceneTitle(title: state.title).frame(width: 0, height: 0))
        }
    }
}

import SwiftUI

struct NativeBrowserPresenter: ViewModifier {
    @Environment(BackendSession.self) private var session
    @Environment(AppCoordinator.self) private var coordinator: AppCoordinator?
    @Environment(\.scenePhase) private var scenePhase
    @State private var windowID = UUID()
    @State private var demoRequested = false
    @State private var displayedID: String?
    @State private var inlineID: String?

    private var navigation: NativeBrowserNavigation { session.browserNavigation }

    func body(content: Content) -> some View {
        content
            .onAppear { navigation.setWindow(windowID, active: scenePhase == .active) }
            .onChange(of: scenePhase) { _, phase in
                navigation.setWindow(windowID, active: phase == .active)
                if phase == .active, let id = displayedID ?? inlineID {
                    navigation.setDisplayed(id, true)
                }
            }
            .onDisappear {
                if navigation.presentation(window: windowID) == nil { navigation.setWindow(windowID, active: false) }
            }
            #if DEBUG
            .task(id: "\(scenePhase)-\(session.connection.connectionState)") {
                guard DemoMode.isEnabled, LaunchOptions.current.contains("--demo-native-browser-navigation"),
                      scenePhase == .active, session.connection.connectionState == .connected, !demoRequested else { return }
                demoRequested = true
                navigation.setWindow(windowID, active: true)
                _ = await navigation.execute([
                    "workspaceId": "demo-ws-dashboard", "agentId": "demo-agent-implementor",
                    "actions": [["action": "openTab", "url": "http://daemon.localhost:5173/preview?view=phone"]]
                ])
            }
            #endif
            .onChange(of: navigation.presentation(window: windowID), initial: true) { placeInline() }
            .onChange(of: coordinator?.iPadNavigation.mainTool?.id) { placeInline() }
            .fullScreenCover(item: Binding(
                get: { navigation.presentation(window: windowID).flatMap(coverBrowser) },
                set: { if $0 == nil { navigation.dismiss(window: windowID) } }
            )) { browser in
                WorkspaceBrowserView(browser: browser, connection: session.connection, onClose: nil) { url, title in
                    navigation.pageChanged(browser.id, url: url, title: title)
                }
                .id(browser.id)
                .onAppear {
                    displayedID = browser.id
                    navigation.setDisplayed(browser.id, scenePhase == .active)
                }
                .onDisappear {
                    if displayedID == browser.id { displayedID = nil }
                    navigation.setDisplayed(browser.id, false)
                }
                .coversConversationComposers()
            }
    }

    private func coverBrowser(_ browser: WorkspaceBrowser) -> WorkspaceBrowser? {
        browser.id == inlineID || coordinator?.canPlaceIPadTool(.browser(browser)) == true ? nil : browser
    }

    private func placeInline() {
        let presented = navigation.presentation(window: windowID)
        let mainTool = coordinator?.iPadNavigation.mainTool
        if let presented, presented.id != inlineID, mainTool?.browserID != presented.id,
           coordinator?.placeIPadTool(.browser(presented)) == true {
            inlineID = presented.id
            return
        }
        guard let inlineID else { return }
        if let presented, presented.id == inlineID, mainTool?.browserID == inlineID {
            coordinator?.iPadNavigation.refreshTool(.browser(presented))
            return
        }
        if mainTool?.browserID == inlineID {
            guard !navigation.hasTab(inlineID) else { return }
            coordinator?.iPadNavigation.closeTool()
        }
        self.inlineID = nil
        if presented?.id == inlineID { navigation.dismiss(window: windowID) }
    }
}

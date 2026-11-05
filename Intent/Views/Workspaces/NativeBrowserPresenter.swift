import SwiftUI

/// One foreground window owns presentation; other windows sharing the backend
/// observe the registry without opening duplicate covers.
struct NativeBrowserPresenter: ViewModifier {
    @Environment(BackendSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var windowID = UUID()
    @State private var demoRequested = false
    @State private var displayedID: String?

    private var navigation: NativeBrowserNavigation { session.browserNavigation }

    func body(content: Content) -> some View {
        content
            .onAppear { navigation.setWindow(windowID, active: scenePhase == .active) }
            .onChange(of: scenePhase) { _, phase in
                navigation.setWindow(windowID, active: phase == .active)
                if phase == .active, let displayedID {
                    navigation.setDisplayed(displayedID, true)
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
            .fullScreenCover(item: Binding(
                get: { navigation.presentation(window: windowID) },
                set: { if $0 == nil { navigation.dismiss(window: windowID) } }
            )) { browser in
                WorkspaceBrowserView(browser: browser, connection: session.connection, onPageChange: { url, title in
                    navigation.pageChanged(browser.id, url: url, title: title)
                })
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
}

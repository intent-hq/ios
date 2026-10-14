import SwiftUI

struct RetainedIPadPane<Content: View>: View {
    let isVisible: Bool
    var keepsCoveredContentVisible = false
    @ViewBuilder let content: Content
    @Environment(\.isIPadPaneVisible) private var parentVisible

    private var isInteractive: Bool { parentVisible && isVisible }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isVisible && (parentVisible || keepsCoveredContentVisible) ? 1 : 0)
            .allowsHitTesting(isInteractive)
            .accessibilityHidden(true, isEnabled: !isInteractive)
            .environment(\.isIPadPaneVisible, isInteractive)
            .transformPreference(WorkspaceActionMenuInputTop.self) { inputTop in
                if !isInteractive { inputTop = nil }
            }
    }
}

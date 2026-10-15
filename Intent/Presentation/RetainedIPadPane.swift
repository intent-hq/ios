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
            .accessibilityHidden(!isInteractive)
            .environment(\.isIPadPaneVisible, isInteractive)
            .transformPreference(WorkspaceActionMenuInputTop.self) { inputTop in
                if !isInteractive { inputTop = nil }
            }
    }
}

/// The resized pane owns its interaction and accessibility bounds. Native lists
/// and navigation containers otherwise report their enclosing window's frame.
struct IPadPaneBounds: ViewModifier {
    let identifier: String
    let isAccessible: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
            .contentShape([.interaction, .accessibility], Rectangle())
            .accessibilityHidden(!isAccessible)
    }
}

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
            // Native containers can otherwise expose hidden descendants through
            // the shell's ancestor accessibility groups. Retain the view, not its AX children.
            .accessibilityElement(children: isInteractive ? .contain : .ignore)
            .accessibilityHidden(true, isEnabled: !isInteractive)
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
            .accessibilityElement(children: isAccessible ? .contain : .ignore)
            .accessibilityIdentifier(identifier)
            .contentShape([.interaction, .accessibility], Rectangle())
            .accessibilityHidden(true, isEnabled: !isAccessible)
    }
}

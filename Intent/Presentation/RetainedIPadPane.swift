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

/// The resized pane owns its interaction and accessibility bounds. Native lists
/// and navigation containers otherwise report their enclosing window's frame.
struct IPadPaneBounds: ViewModifier {
    let identifier: String
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
            .accessibilityFrame(frame)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

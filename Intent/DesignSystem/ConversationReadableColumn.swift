import SwiftUI

extension View {
    /// Constrain the transcript and composer; navigation stays outside this column.
    func conversationReadableColumn() -> some View {
        modifier(ConversationReadableColumn(fillsWidePanel: true))
    }

    /// Detail children already own their page inset, so count it outside the readable body.
    func iPadDetailColumn(isEnabled: Bool = true) -> some View {
        modifier(ConversationReadableColumn(contentHorizontalInset: WorkspaceDetailStyle.pageInset, isEnabled: isEnabled))
    }
}

private struct ConversationReadableColumn: ViewModifier {
    var fillsWidePanel = false
    var contentHorizontalInset: CGFloat = 0
    var isEnabled = true
    @Environment(\.conversationPresentation) private var presentation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar
    @State private var availableWidth: CGFloat = 0

    private typealias Layout = Constants.Conversation.Design.IPad

    /// The Duo keeps the narrow column: a closed drawer spans the chat across the fold.
    private var readableWidth: CGFloat {
        fillsWidePanel && !usesVerticalBar ? Layout.conversationMaximumWidth : Layout.readableWidth
    }

    private var maximumWidth: CGFloat {
        isEnabled && presentation == .iPad && !dynamicTypeSize.isAccessibilitySize
            ? readableWidth + 2 * contentHorizontalInset : .infinity
    }

    private var horizontalInset: CGFloat {
        guard isEnabled, presentation == .iPad else { return 0 }
        let inset = availableWidth >= Layout.readableWidth + Layout.horizontalInset * 2
            ? Layout.horizontalInset : Layout.minimumHorizontalInset
        return max(0, inset - contentHorizontalInset)
    }

    func body(content: Content) -> some View {
        // Keep one structural identity as the window or sidebar changes size.
        content
            .frame(maxWidth: maximumWidth)
            .padding(.horizontal, horizontalInset)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }
}

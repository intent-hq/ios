import SwiftUI

extension View {
    /// Constrain the transcript and composer; navigation stays outside this column.
    func conversationReadableColumn() -> some View {
        modifier(ConversationReadableColumn())
    }

    /// Detail children already own their page inset, so count it outside the readable body.
    func iPadDetailColumn() -> some View {
        modifier(ConversationReadableColumn(contentHorizontalInset: WorkspaceDetailStyle.pageInset))
    }
}

private struct ConversationReadableColumn: ViewModifier {
    var contentHorizontalInset: CGFloat = 0
    @Environment(\.conversationPresentation) private var presentation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var availableWidth: CGFloat = 0

    private typealias Layout = Constants.Conversation.Design.IPad

    private var maximumWidth: CGFloat {
        presentation == .iPad && !dynamicTypeSize.isAccessibilitySize
            ? Layout.readableWidth + 2 * contentHorizontalInset : .infinity
    }

    private var horizontalInset: CGFloat {
        guard presentation == .iPad else { return 0 }
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

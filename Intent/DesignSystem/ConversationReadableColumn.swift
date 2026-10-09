import SwiftUI

extension View {
    /// Apply once around the conversation's header, transcript and composer together.
    /// Other detail routes retain the full pane width supplied by the shell.
    func conversationReadableColumn() -> some View {
        modifier(ConversationReadableColumn())
    }
}

private struct ConversationReadableColumn: ViewModifier {
    @Environment(\.conversationPresentation) private var presentation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var availableWidth: CGFloat = 0

    private typealias Layout = Constants.Conversation.Design.IPad

    private var maximumWidth: CGFloat {
        presentation == .iPad && !dynamicTypeSize.isAccessibilitySize ? Layout.readableWidth : .infinity
    }

    private var horizontalInset: CGFloat {
        guard presentation == .iPad else { return 0 }
        return availableWidth >= Layout.readableWidth + Layout.horizontalInset * 2
            ? Layout.horizontalInset : Layout.minimumHorizontalInset
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

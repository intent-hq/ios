import SwiftUI

enum ConversationPresentation: Equatable {
    case iPad
    case standard
}

extension EnvironmentValues {
    @Entry var conversationComposerFocus: Binding<Bool>?
    @Entry var conversationPresentation: ConversationPresentation = .standard
    @Entry var conversationBackgroundColor: Color?
    @Entry var conversationComposerBackgroundColor: Color?
    @Entry var iPadFocusPresentation: Binding<IPadFocusPresentation>?
    @Entry var isIPadPaneVisible = true
}

struct ConversationScrollEdgeEffect: ViewModifier {
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(usesVerticalBar, for: .top)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

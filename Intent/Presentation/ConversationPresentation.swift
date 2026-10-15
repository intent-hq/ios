import SwiftUI

/// Explicit presentation policy: a narrow iPad window still has iPad chrome.
enum ConversationPresentation: Equatable {
    case iPad
    case standard
}

extension EnvironmentValues {
    @Entry var conversationComposerFocus: Binding<Bool>?
    @Entry var conversationPresentation: ConversationPresentation = .standard
    @Entry var iPadFocusPresentation: Binding<IPadFocusPresentation>?
    /// Hidden iPad panes retain state but must relinquish keyboard focus.
    @Entry var isIPadPaneVisible = true
}

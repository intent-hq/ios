import SwiftUI

/// Input focus controls the retained iPad pane independently of keyboard visibility.
struct IPadTypingFocus: ViewModifier {
    @Binding var isFocused: Bool
    let composerVisible: Bool
    @Environment(\.iPadFocusPresentation) private var iPadFocusPresentation
    @Environment(\.isIPadPaneVisible) private var isIPadPaneVisible

    func body(content: Content) -> some View {
        content
            .onChange(of: isFocused) { _, focused in
                if focused, isIPadPaneVisible {
                    iPadFocusPresentation?.wrappedValue = .conversationEditing
                }
            }
            .onChange(of: iPadFocusPresentation?.wrappedValue) { _, focus in
                if focus != .conversationEditing { isFocused = false }
            }
            .onChange(of: composerVisible) { _, visible in
                if !visible, isIPadPaneVisible, iPadFocusPresentation?.wrappedValue == .conversationEditing {
                    isFocused = false
                    iPadFocusPresentation?.wrappedValue = .normal
                }
            }
            .onDisappear {
                guard iPadFocusPresentation != nil else { return }
                if isFocused { iPadFocusPresentation?.wrappedValue = .normal }
                isFocused = false
            }
    }
}

/// Keeps the same editor subtree while its adjacent close control appears.
struct IPadTypingFocusRow<Content: View>: View {
    @Binding var isFocused: Bool
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.iPadFocusPresentation) private var iPadFocusPresentation
    @Environment(\.isIPadPaneVisible) private var isIPadPaneVisible

    var body: some View {
        HStack(alignment: .bottom, spacing: Constants.WorkspaceSearch.contentSpacing) {
            content
            if isIPadPaneVisible, iPadFocusPresentation?.wrappedValue == .conversationEditing {
                closeFocusButton
            }
        }
        .fixedSize(horizontal: false, vertical: iPadFocusPresentation != nil)
    }

    private var closeFocusButton: some View {
        Button {
            isFocused = false
            iPadFocusPresentation?.wrappedValue = .normal
        } label: {
            Image(.close)
                .resizable()
                .scaledToFit()
                .frame(width: Constants.Conversation.Design.iconSize, height: Constants.Conversation.Design.iconSize)
                .foregroundStyle(Constants.Conversation.Design.Palette.foreground(for: colorScheme))
                .frame(width: Constants.Conversation.Design.Composer.minimumHeight, height: Constants.Conversation.Design.Composer.minimumHeight)
                .background(
                    Constants.Conversation.Design.Palette.surface(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: Constants.Conversation.Design.cornerRadius)
                )
                .accessibilityHidden(true)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Close typing focus")
        .accessibilityIdentifier("ipad.focus.close")
        .keyboardShortcut(.cancelAction)
    }
}

/// Hides only navigation chrome while the existing conversation fills its focus panel.
struct ConversationFocusHeaderInset<Header: View>: ViewModifier {
    let isEnabled: Bool
    /// Untitled controls float over the content instead of reserving a header band.
    var floats = false
    @ViewBuilder let header: Header
    @Environment(\.iPadFocusPresentation) private var iPadFocusPresentation

    private var showsHeader: Bool { isEnabled && iPadFocusPresentation?.wrappedValue != .conversationEditing }

    // Both placements stay attached so switching between them keeps the content's identity and scroll.
    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsHeader, !floats { header }
            }
            .overlay(alignment: .top) {
                if showsHeader, floats { header }
            }
    }
}

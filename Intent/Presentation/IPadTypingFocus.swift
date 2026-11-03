import SwiftUI
import UIKit

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
    var floats = false
    @ViewBuilder let header: (Bool) -> Header
    @Environment(\.iPadFocusPresentation) private var iPadFocusPresentation
    @State private var usesMiniHeader = false

    private var showsHeader: Bool { isEnabled && iPadFocusPresentation?.wrappedValue != .conversationEditing }
    private var floatsOverContent: Bool { floats && !usesMiniHeader }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsHeader, !floatsOverContent { header(usesMiniHeader) }
            }
            .overlay(alignment: .top) {
                if showsHeader, floatsOverContent { header(usesMiniHeader) }
            }
            .background {
                ConversationHeaderScreenReader { usesMiniHeader = $0 }
                    .frame(width: 0, height: 0)
            }
    }
}

enum ConversationHeaderLayout {
    static func usesMiniHeader(isPad: Bool, screenSize: CGSize) -> Bool {
        let shortSide = min(screenSize.width, screenSize.height)
        return isPad && shortSide > 0 && shortSide < IPadShellLayout.tightRailShortSide
    }
}

private struct ConversationHeaderScreenReader: UIViewRepresentable {
    let onResolve: (Bool) -> Void

    func makeUIView(context _: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_ view: ReaderView, context _: Context) {
        view.onResolve = onResolve
    }

    final class ReaderView: UIView {
        var onResolve: ((Bool) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene, let onResolve else { return }
            let screen = scene.screen
            let usesMiniHeader = ConversationHeaderLayout.usesMiniHeader(
                isPad: traitCollection.userInterfaceIdiom == .pad,
                screenSize: CGSize(width: screen.nativeBounds.width / screen.scale, height: screen.nativeBounds.height / screen.scale)
            )
            DispatchQueue.main.async { onResolve(usesMiniHeader) }
        }
    }
}

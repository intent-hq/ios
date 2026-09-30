import SwiftUI

/// Agent actions in a native popover, using the Figma dropdown's grouped brand treatment.
struct ConversationActionMenu: View {
    enum Action: String {
        case changeModel = "model"
        case delete
        case rename
    }

    let modelDisplayName: String?
    let canChangeModel: Bool
    let onAction: (Action) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isPresented = false
    @State private var pendingAction: Action?

    private typealias Palette = Constants.Conversation.Design.Palette

    var body: some View {
        Button {
            pendingAction = nil
            isPresented = true
        } label: {
            ToolbarOverflowLabel()
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Agent actions")
        .accessibilityIdentifier("conversation.actions.open")
        .popover(isPresented: $isPresented) {
            popoverContent
                .presentationCompactAdaptation(.popover)
                .presentationBackground(Palette.background(for: colorScheme))
                .presentationCornerRadius(ConversationActionMenuStyle.cornerRadius)
                .onDisappear(perform: completeSelection)
        }
    }

    private var popoverContent: some View {
        ViewThatFits(in: .vertical) {
            actionGroups
            ScrollView {
                actionGroups
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(
            minWidth: 0,
            idealWidth: ConversationActionMenuStyle.preferredWidth,
            maxWidth: ConversationActionMenuStyle.preferredWidth
        )
        .background(Palette.background(for: colorScheme))
        .clipShape(.rect(cornerRadius: ConversationActionMenuStyle.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ConversationActionMenuStyle.cornerRadius)
                .strokeBorder(outline, lineWidth: ConversationActionMenuStyle.borderWidth)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.actions.menu")
        .accessibilityAction(.escape) { isPresented = false }
    }

    private var actionGroups: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let modelDisplayName {
                    Text("Model: \(modelDisplayName)")
                        .interFont(Constants.Typography.bodySEmphasized)
                        .tracking(Constants.Conversation.Design.Typography.compactBodyTracking)
                        .foregroundStyle(Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, ConversationActionMenuStyle.rowInset)
                        .padding(.vertical, ConversationActionMenuStyle.groupInset)
                        .accessibilityIdentifier("conversation.actions.modelInformation")
                }
                if canChangeModel {
                    actionButton("Change Model", image: .settings2, action: .changeModel)
                }
                actionButton("Rename", image: .edit, action: .rename)
            }
            .padding(ConversationActionMenuStyle.groupInset)

            Rectangle()
                .fill(outline)
                .frame(height: ConversationActionMenuStyle.borderWidth)
                .accessibilityHidden(true)

            actionButton("Delete Agent", image: .delete, action: .delete)
                .padding(ConversationActionMenuStyle.groupInset)
        }
    }

    private func actionButton(_ title: String, image: ImageResource, action: Action) -> some View {
        Button(role: action == .delete ? .destructive : nil) {
            pendingAction = action
            isPresented = false
        } label: {
            HStack(spacing: ConversationActionMenuStyle.labelGap) {
                Image(image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Constants.Conversation.Design.iconSize, height: Constants.Conversation.Design.iconSize)
                    .accessibilityHidden(true)
                Text(title)
                    .interFont(Constants.Typography.bodySEmphasized)
                    .tracking(Constants.Conversation.Design.Typography.compactBodyTracking)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(action == .delete ? Theme.destructive(for: colorScheme) : Palette.foreground(for: colorScheme))
            .padding(.horizontal, ConversationActionMenuStyle.rowInset)
            .padding(.vertical, ConversationActionMenuStyle.groupInset)
            .frame(maxWidth: .infinity, minHeight: ConversationActionMenuStyle.minimumRowHeight, alignment: .leading)
            .contentShape(.rect(cornerRadius: ConversationActionMenuStyle.rowCornerRadius))
        }
        .buttonStyle(ConversationActionButtonStyle())
        .accessibilityIdentifier("conversation.actions.\(action.rawValue)")
        .disabled(pendingAction != nil)
        .hoverEffect(.highlight)
    }

    private var outline: Color {
        if contrast == .increased {
            return Palette.border(for: colorScheme, contrast: contrast)
        }
        return colorScheme == .dark ? ConversationActionMenuStyle.darkOutline : ConversationActionMenuStyle.lightOutline
    }

    private func completeSelection() {
        // Popover content must disappear before the parent presents an alert or sheet.
        // Outside taps and accessibility dismissal have no pending action.
        guard !isPresented, let action = pendingAction else { return }
        pendingAction = nil
        onAction(action)
    }
}

private struct ConversationActionButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Constants.Conversation.Design.Palette.surface(for: colorScheme) : .clear,
                in: .rect(cornerRadius: ConversationActionMenuStyle.rowCornerRadius)
            )
    }
}

private enum ConversationActionMenuStyle {
    // Dropdowns 3012:33278 (dark) and 3012:33393 (light). Width adapts to the native popover proposal.
    static let preferredWidth: CGFloat = 300
    static let cornerRadius: CGFloat = 24
    static let rowCornerRadius: CGFloat = 16
    static let borderWidth: CGFloat = 1
    static let groupInset: CGFloat = 8
    static let rowInset: CGFloat = 24
    static let labelGap: CGFloat = 20
    static let minimumRowHeight: CGFloat = 56

    // Outline/Outline 10% Solid is distinct from the conversation's translucent border.
    // swiftlint:disable no_magic_numbers
    static let darkOutline = Color(.sRGB, white: 61 / 255, opacity: 1)
    static let lightOutline = Color(.sRGB, white: 229 / 255, opacity: 1)
    // swiftlint:enable no_magic_numbers
}

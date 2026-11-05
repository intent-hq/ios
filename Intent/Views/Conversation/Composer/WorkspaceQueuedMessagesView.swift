import SwiftUI

/// Workspace-only queue presentation. Commands still belong to the conversation owner.
struct WorkspaceQueuedMessagesView: View {
    let viewModel: ConversationViewModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var editingId: String?
    @State private var editText = ""

    private typealias Design = Constants.Conversation.Design
    private typealias Layout = Design.Queue

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            Text(viewModel.queuedMessages.count == 1 ? "QUEUED MESSAGE" : "QUEUED MESSAGES")
                .interFont(Constants.Typography.eyebrow)
                .tracking(Layout.headerTracking)
                .foregroundStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("queue.header")

            VStack(spacing: Layout.rowSpacing) {
                ForEach(viewModel.queuedMessages) { message in
                    WorkspaceQueuedMessageRow(viewModel: viewModel, message: message, editingId: $editingId, editText: $editText)
                }
            }
        }
        .foregroundStyle(Design.Palette.foreground(for: colorScheme))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkspaceQueuedMessageRow: View {
    let viewModel: ConversationViewModel
    let message: QueuedMessage
    @Binding var editingId: String?
    @Binding var editText: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Design = Constants.Conversation.Design
    private typealias Layout = Design.Queue

    var body: some View {
        HStack(spacing: Layout.textActionSpacing - Layout.controlInset) {
            if editingId == message.id {
                TextField("Edit message", text: $editText)
                    .textFieldStyle(.plain)
                    .interFont(Constants.Typography.bodyS)
                    .tracking(Design.Typography.bodyTracking)
                    .onSubmit { saveEdit() }
                    .accessibilityIdentifier("queue.editor.\(message.id)")
                HStack(spacing: Layout.actionSpacing) {
                    action(.checkCircle, label: "Save queued message edit", perform: saveEdit)
                    action(.closeCircle, label: "Cancel queued message edit") { editingId = nil }
                }
            } else {
                Text(message.content)
                    .interFont(Constants.Typography.bodyS)
                    .tracking(Design.Typography.bodyTracking)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("queue.message.\(message.id)")
                displayActions
            }
        }
        // Keep the reference's glyph spacing while giving each action a
        // non-overlapping 44pt hit region. The surrounding gaps absorb the inset.
        .padding(.trailing, -Layout.controlInset)
        .padding(.vertical, -Layout.controlInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue.row.\(message.id)")
    }

    private var displayActions: some View {
        HStack(spacing: Layout.actionSpacing) {
            action(.arrowUp, label: "Send queued message now") {
                Task { await viewModel.sendQueuedMessageNow(messageId: message.id) }
            }
            action(.edit, label: "Edit queued message") {
                editingId = message.id
                editText = message.content
            }
            action(.close, label: "Remove queued message") {
                Task { await viewModel.removeQueuedMessage(messageId: message.id) }
            }
        }
    }

    private func action(_ image: ImageResource, label: LocalizedStringKey, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(image)
                .resizable()
                .scaledToFit()
                .frame(width: Design.iconSize, height: Design.iconSize)
                .foregroundStyle(Design.Palette.placeholderForeground(for: colorScheme, contrast: contrast))
                .frame(width: Design.minimumTapTarget, height: Design.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel(label)
    }

    private func saveEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task { await viewModel.editQueuedMessage(messageId: message.id, content: text) }
        editingId = nil
    }
}

/// Wraps the existing composer without changing its identity as the queue appears/disappears.
struct WorkspaceQueuePanel<Content: View>: View {
    let viewModel: ConversationViewModel
    let isVisible: Bool
    var horizontalInset = Constants.Conversation.Design.horizontalInset
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationBackgroundColor) private var backgroundColor
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        VStack(spacing: 0) {
            if isVisible {
                WorkspaceQueuedMessagesView(viewModel: viewModel)
                    .padding(.horizontal, horizontalInset)
                    .padding(.top, Design.Queue.topPadding)
                    .padding(.bottom, Design.Queue.composerSpacing)
            }
            content
        }
        .background {
            if isVisible, !viewModel.showsLoadingState {
                (backgroundColor ?? Design.Palette.background(for: colorScheme)).ignoresSafeArea(edges: .bottom)
            }
        }
        .overlay(alignment: .top) {
            if isVisible {
                Design.Palette.border(for: colorScheme, contrast: contrast)
                    .frame(height: Design.Queue.borderWidth)
                    .accessibilityHidden(true)
            }
        }
    }
}

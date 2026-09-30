import SwiftUI

struct QueuedMessagesView: View {
    let viewModel: ConversationViewModel
    @Environment(\.colorScheme) var colorScheme

    @ScaledMetric(relativeTo: .body) private var actionIconSide: CGFloat = 17

    private typealias Layout = Constants.Conversation.QueuedMessage

    @State private var editingId: String?
    @State private var editText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.badge.questionmark")
                    .font(.caption)
                    .accessibilityHidden(true)
                Text("Queued Messages (\(viewModel.queuedMessages.count))")
                    .interFont(Constants.Typography.subtextXXS.withFace(.medium))
                Spacer()
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .padding(.horizontal, Layout.headerHorizontalPadding)
            .padding(.top, Layout.headerTopPadding)
            .padding(.bottom, Layout.headerBottomPadding)

            ForEach(viewModel.queuedMessages) { message in
                queuedMessageRow(message)
            }
        }
        .background(Theme.card(for: colorScheme).opacity(Layout.backgroundOpacity))
    }

    @ViewBuilder
    private func queuedMessageRow(_ message: QueuedMessage) -> some View {
        HStack(spacing: Layout.rowSpacing) {
            if editingId == message.id {
                editingRow(message)
            } else {
                displayRow(message)
            }
        }
        .padding(.horizontal, Layout.rowHorizontalPadding)
        .padding(.vertical, Layout.rowVerticalPadding)
    }

    @ViewBuilder
    private func editingRow(_ message: QueuedMessage) -> some View {
        TextField("Edit message", text: $editText)
            .textFieldStyle(.plain)
            .interFont(Constants.Typography.bodyXS)
            .onSubmit { saveEdit(messageId: message.id) }
        saveEditButton(message)
        cancelEditButton
    }

    @ViewBuilder
    private func displayRow(_ message: QueuedMessage) -> some View {
        Text(message.content)
            .interFont(Constants.Typography.bodyXS)
            .foregroundStyle(Theme.foreground(for: colorScheme))
            .lineLimit(Layout.contentLineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
        sendNowButton(message)
        editButton(message)
        removeButton(message)
    }

    private func saveEditButton(_ message: QueuedMessage) -> some View {
        Button {
            saveEdit(messageId: message.id)
        } label: {
            Image(.checkCircle)
                .resizable()
                .scaledToFit()
                .frame(width: actionIconSide, height: actionIconSide)
                .foregroundStyle(Theme.primary(for: colorScheme))
                .frame(
                    width: Constants.Conversation.QueuedMessage.actionButtonSide,
                    height: Constants.Conversation.QueuedMessage.actionButtonSide
                )
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Save queued message edit")
    }

    private var cancelEditButton: some View {
        Button {
            editingId = nil
        } label: {
            Image(.closeCircle)
                .resizable()
                .scaledToFit()
                .frame(width: actionIconSide, height: actionIconSide)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .frame(
                    width: Constants.Conversation.QueuedMessage.actionButtonSide,
                    height: Constants.Conversation.QueuedMessage.actionButtonSide
                )
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Cancel queued message edit")
    }

    private func editButton(_ message: QueuedMessage) -> some View {
        Button {
            editingId = message.id
            editText = message.content
        } label: {
            Image(.edit)
                .resizable()
                .scaledToFit()
                .frame(width: actionIconSide, height: actionIconSide)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .frame(
                    width: Constants.Conversation.QueuedMessage.actionButtonSide,
                    height: Constants.Conversation.QueuedMessage.actionButtonSide
                )
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Edit queued message")
    }

    private func sendNowButton(_ message: QueuedMessage) -> some View {
        Button {
            Task { await viewModel.sendQueuedMessageNow(messageId: message.id) }
        } label: {
            Image(systemName: "paperplane.fill")
                .font(.body)
                .foregroundStyle(Theme.primary(for: colorScheme))
                .frame(
                    width: Constants.Conversation.QueuedMessage.actionButtonSide,
                    height: Constants.Conversation.QueuedMessage.actionButtonSide
                )
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Send queued message now")
    }

    private func removeButton(_ message: QueuedMessage) -> some View {
        Button {
            Task { await viewModel.removeQueuedMessage(messageId: message.id) }
        } label: {
            Image(.close)
                .resizable()
                .scaledToFit()
                .frame(width: actionIconSide, height: actionIconSide)
                .foregroundStyle(Theme.destructive(for: colorScheme))
                .frame(
                    width: Constants.Conversation.QueuedMessage.actionButtonSide,
                    height: Constants.Conversation.QueuedMessage.actionButtonSide
                )
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Remove queued message")
    }

    private func saveEdit(messageId: String) {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task { await viewModel.editQueuedMessage(messageId: messageId, content: text) }
        editingId = nil
    }
}

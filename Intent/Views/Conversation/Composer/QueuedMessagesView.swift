import SwiftUI

struct QueuedMessagesView: View {
    let viewModel: ConversationViewModel
    @Environment(\.colorScheme) var colorScheme

    private static let headerHorizontalPadding: CGFloat = 16
    private static let headerTopPadding: CGFloat = 8
    private static let headerBottomPadding: CGFloat = 4
    private static let backgroundOpacity = 0.8
    private static let rowSpacing: CGFloat = 8
    private static let rowHorizontalPadding: CGFloat = 16
    private static let rowVerticalPadding: CGFloat = 6

    @State private var editingId: String?
    @State private var editText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.badge.questionmark")
                    .font(.caption)
                    .accessibilityHidden(true)
                Text("Queued Messages (\(viewModel.queuedMessages.count))")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .padding(.horizontal, Self.headerHorizontalPadding)
            .padding(.top, Self.headerTopPadding)
            .padding(.bottom, Self.headerBottomPadding)

            ForEach(viewModel.queuedMessages) { message in
                queuedMessageRow(message)
            }
        }
        .background(Theme.card(for: colorScheme).opacity(Self.backgroundOpacity))
    }

    @ViewBuilder
    private func queuedMessageRow(_ message: QueuedMessage) -> some View {
        HStack(spacing: Self.rowSpacing) {
            if editingId == message.id {
                editingRow(message)
            } else {
                displayRow(message)
            }
        }
        .padding(.horizontal, Self.rowHorizontalPadding)
        .padding(.vertical, Self.rowVerticalPadding)
    }

    @ViewBuilder
    private func editingRow(_ message: QueuedMessage) -> some View {
        TextField("Edit message", text: $editText)
            .textFieldStyle(.plain)
            .font(.subheadline)
            .onSubmit { saveEdit(messageId: message.id) }
        saveEditButton(message)
        cancelEditButton
    }

    @ViewBuilder
    private func displayRow(_ message: QueuedMessage) -> some View {
        Text(message.content)
            .font(.subheadline)
            .foregroundStyle(Theme.foreground(for: colorScheme))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        sendNowButton(message)
        editButton(message)
        removeButton(message)
    }

    private func saveEditButton(_ message: QueuedMessage) -> some View {
        Button {
            saveEdit(messageId: message.id)
        } label: {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
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
            Image(systemName: "xmark.circle")
                .font(.body)
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
            Image(systemName: "pencil")
                .font(.body)
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
            Image(systemName: "xmark")
                .font(.body)
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

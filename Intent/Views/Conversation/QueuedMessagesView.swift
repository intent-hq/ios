import SwiftUI

struct QueuedMessagesView: View {
    @ObservedObject var viewModel: ConversationViewModel
    @Environment(\.colorScheme) var colorScheme

    @State private var editingId: String?
    @State private var editText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.badge.questionmark")
                    .font(.caption)
                Text("Queued Messages (\(viewModel.queuedMessages.count))")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ForEach(viewModel.queuedMessages) { message in
                queuedMessageRow(message)
            }
        }
        .background(Theme.card(for: colorScheme).opacity(0.8))
    }

    @ViewBuilder
    private func queuedMessageRow(_ message: QueuedMessage) -> some View {
        HStack(spacing: 8) {
            if editingId == message.id {
                // Inline editing
                TextField("Edit message", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .onSubmit { saveEdit(messageId: message.id) }

                Button {
                    saveEdit(messageId: message.id)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(Theme.primary(for: colorScheme))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }

                Button {
                    editingId = nil
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.body)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            } else {
                // Display mode
                Text(message.content)
                    .font(.subheadline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await viewModel.sendQueuedMessageNow(messageId: message.id) }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.body)
                        .foregroundStyle(Theme.primary(for: colorScheme))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }

                Button {
                    editingId = message.id
                    editText = message.content
                } label: {
                    Image(systemName: "pencil")
                        .font(.body)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }

                Button {
                    Task { await viewModel.removeQueuedMessage(messageId: message.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.body)
                        .foregroundStyle(Theme.destructive(for: colorScheme))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func saveEdit(messageId: String) {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task { await viewModel.editQueuedMessage(messageId: messageId, content: text) }
        editingId = nil
    }
}


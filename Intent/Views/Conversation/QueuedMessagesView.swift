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
            } else if let hookWake = message.hookWakeAttribution {
                // Background-hook wake (PROTOCOL §5.40): compact attribution
                // row, not user-editable (FE parity: QueuedMessageList).
                wakeRowLabel(
                    icon: "bolt.fill",
                    name: hookWake.displayName,
                    preview: HookWakeAttribution.displayText(message.content, attribution: hookWake))
                sendNowButton(message)
                removeButton(message)
            } else if let prWake = message.prMonitorWakeAttribution {
                // PR-monitor wake (PROTOCOL §5.42): compact attribution row,
                // not user-editable (FE parity: QueuedMessageList).
                wakeRowLabel(
                    icon: "arrow.triangle.pull",
                    name: prWake.chipLabel(workspaceRepo: viewModel.workspaceRepo),
                    preview: PrMonitorWakeAttribution.displayText(message.content))
                sendNowButton(message)
                removeButton(message)
            } else {
                // Display mode
                Text(message.content)
                    .font(.subheadline)
                    .foregroundStyle(Theme.foreground(for: colorScheme))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                sendNowButton(message)

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

                removeButton(message)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// Compact wake-attribution label: icon + bold source name + a muted
    /// one-line preview of the display-stripped wake message.
    @ViewBuilder
    private func wakeRowLabel(icon: String, name: String, preview: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            (Text(name).font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.foreground(for: colorScheme))
                + Text(preview.isEmpty ? "" : " — \(preview)")
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme)))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sendNowButton(_ message: QueuedMessage) -> some View {
        Button {
            Task { await viewModel.sendQueuedMessageNow(messageId: message.id) }
        } label: {
            Image(systemName: "paperplane.fill")
                .font(.body)
                .foregroundStyle(Theme.primary(for: colorScheme))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
    }

    private func removeButton(_ message: QueuedMessage) -> some View {
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

    private func saveEdit(messageId: String) {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task { await viewModel.editQueuedMessage(messageId: messageId, content: text) }
        editingId = nil
    }
}


import SwiftUI

struct ProposalCardView: View {
    let proposal: ActionProposal
    @Environment(ProposalActionStore.self) private var store: ProposalActionStore?
    @Environment(\.proposalMessageId) private var messageId
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: Set<String>
    @State private var confirmingDismiss = false

    private enum Layout {
        static let spacing: CGFloat = 12
        static let padding: CGFloat = 16
        static let cornerRadius: CGFloat = 16
        static let minimumRowHeight: CGFloat = 44
    }

    init(proposal: ActionProposal) {
        self.proposal = proposal
        _selection = State(initialValue: proposal.initialSelection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            Text(proposal.preview.title).font(.headline)
            if let summary = proposal.preview.summary { Text(summary).foregroundStyle(.secondary) }
            if let store {
                proposalContent(store)
            } else {
                Text("Open this action in the desktop app.").font(.callout)
            }
        }
        .padding(Layout.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.muted(for: colorScheme), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
        .task { await store?.refresh() }
        .confirmationDialog("Dismiss this proposal?", isPresented: $confirmingDismiss, titleVisibility: .visible) {
            Button("Dismiss proposal", role: .destructive) {
                Task { await store?.dismiss(proposal, messageId: messageId) }
            }
        } message: {
            Text("The Assistant will be told that you dismissed it.")
        }
    }

    @ViewBuilder private func proposalContent(_ store: ProposalActionStore) -> some View {
        if store.isPending(proposal, messageId: messageId) {
            if proposal.method != nil {
                itemList(store)
            } else {
                Text("This action is not supported on iOS yet. Open it in the desktop app.")
            }
            ForEach(proposal.preview.warnings, id: \.self) { warning in
                Text(warning).font(.callout)
            }
            if let error = store.errors[proposal.id] {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            actionButtons(store)
        } else if let outcome = store.resolutions[proposal.id] {
            Text(outcome == "applied" ? "Applied" : "Dismissed")
                .accessibilityIdentifier("proposal.outcome")
        } else if let error = store.loadError {
            Text(error).font(.callout)
            Button {
                Task { await store.refresh() }
            } label: {
                Text("Retry")
                    .copyContextMenuPassthrough()
            }
        } else {
            Text("Waiting for confirmation availability…").font(.callout)
        }
    }

    private func itemList(_ store: ProposalActionStore) -> some View {
        let completed = store.completed[store.receiptKey(proposal, messageId: messageId)] ?? []
        return VStack(alignment: .leading, spacing: Layout.spacing) {
            ForEach(proposal.items) { item in
                selectionButton(item, isCompleted: completed.contains(item.id))
                    .disabled(item.disabled == true || completed.contains(item.id) || store.isBusy)
            }
        }
    }

    private func selectionButton(_ item: ActionProposal.Item, isCompleted: Bool) -> some View {
        Button {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } label: {
            HStack(spacing: Layout.spacing) {
                Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(item.title)
                    if let summary = item.summary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                    if isCompleted { Text("Applied").font(.caption) }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Layout.minimumRowHeight)
            .contentShape(Rectangle())
            .copyContextMenuPassthrough()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection.contains(item.id) ? .isSelected : [])
        .accessibilityIdentifier("proposal.item.\(item.id)")
    }

    private func actionButtons(_ store: ProposalActionStore) -> some View {
        HStack {
            Button {
                confirmingDismiss = true
            } label: {
                Text("Not now")
                    .copyContextMenuPassthrough()
            }
            .accessibilityIdentifier("proposal.dismiss")
            Spacer()
            if proposal.method != nil {
                Button {
                    Task { await store.apply(proposal, messageId: messageId, selection: selection) }
                } label: {
                    Text(proposal.method == "workspace.delete" ? "Delete" : "Archive")
                        .copyContextMenuPassthrough()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("proposal.apply")
            }
            if store.isBusy { ProgressView() }
        }
        .disabled(store.isBusy)
    }
}

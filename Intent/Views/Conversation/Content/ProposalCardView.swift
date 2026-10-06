import SwiftUI

struct ProposalCardView: View {
    let proposal: ActionProposal
    @Environment(ProposalActionStore.self) private var store: ProposalActionStore?
    @Environment(\.proposalMessageId) private var messageId
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.workspaceTranscriptDesign) private var usesWorkspaceDesign
    @State private var selection: Set<String>
    @State private var confirmingDismiss = false

    private enum Layout {
        static let spacing: CGFloat = 12
        static let padding: CGFloat = 16
        static let cornerRadius: CGFloat = 16
        static let minimumRowHeight: CGFloat = 44
    }

    private typealias Design = Constants.Conversation.Design

    private var cornerRadius: CGFloat { usesWorkspaceDesign ? Design.cornerRadius : Layout.cornerRadius }
    private var secondaryForeground: AnyShapeStyle {
        usesWorkspaceDesign ? AnyShapeStyle(Design.Palette.secondaryForeground(for: colorScheme, contrast: contrast)) : AnyShapeStyle(.secondary)
    }

    private func font(_ style: Constants.Typography.Style, fallback: Font) -> Font {
        usesWorkspaceDesign ? style.font(legibilityWeight: legibilityWeight) : fallback
    }

    init(proposal: ActionProposal) {
        self.proposal = proposal
        _selection = State(initialValue: proposal.initialSelection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            Text(proposal.preview.title)
                .font(font(Constants.Typography.bodySEmphasized, fallback: .headline))
            if let summary = proposal.preview.summary { Text(summary).foregroundStyle(secondaryForeground) }
            if let store {
                proposalContent(store)
            } else {
                Text("Open this action in the desktop app.").font(font(Constants.Typography.bodyXS, fallback: .callout))
            }
        }
        .font(usesWorkspaceDesign ? font(Constants.Typography.bodyS, fallback: .body) : nil)
        .foregroundStyle(usesWorkspaceDesign ? AnyShapeStyle(Design.Palette.foreground(for: colorScheme)) : AnyShapeStyle(.primary))
        .padding(usesWorkspaceDesign ? Design.Transcript.bubblePadding : Layout.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(usesWorkspaceDesign ? Design.Palette.surface(for: colorScheme) : Theme.muted(for: colorScheme), in: .rect(cornerRadius: cornerRadius))
        .overlay {
            if usesWorkspaceDesign {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Design.Palette.border(for: colorScheme, contrast: contrast))
                    .allowsHitTesting(false)
            }
        }
        .task { await store?.loadIfNeeded() }
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
                Text(warning).font(font(Constants.Typography.bodyXS, fallback: .callout))
            }
            if let error = store.errors[proposal.id] {
                Text(error)
                    .font(font(Constants.Typography.bodyXS, fallback: .callout))
                    .foregroundStyle(usesWorkspaceDesign ? Theme.destructive(for: colorScheme) : .red)
            }
            actionButtons(store)
        } else if let outcome = store.resolutions[proposal.id] {
            Text(outcome == "applied" ? "Applied" : "Dismissed")
                .accessibilityIdentifier("proposal.outcome")
        } else if let error = store.loadError {
            Text(error).font(font(Constants.Typography.bodyXS, fallback: .callout))
            Button {
                Task { await store.refresh() }
            } label: {
                Text("Retry")
                    .copyContextMenuPassthrough()
            }
            .buttonStyle(IntentButtonStyle(variant: .secondary))
        } else {
            Text("Waiting for confirmation availability…").font(font(Constants.Typography.bodyXS, fallback: .callout))
        }
    }

    private func itemList(_ store: ProposalActionStore) -> some View {
        let completed = store.completed[store.receiptKey(proposal, messageId: messageId)] ?? []
        let isBusy = store.isBusy
        // Read selection and store state on MainActor, not in the row provider.
        let rows = proposal.items.map { item in
            let isCompleted = completed.contains(item.id)
            let content = selectionButton(item, isCompleted: isCompleted, isSelected: selection.contains(item.id))
                .disabled(item.disabled == true || isCompleted || isBusy)
            return (id: item.id, content: content)
        }
        return VStack(alignment: .leading, spacing: Layout.spacing) {
            ForEach(rows, id: \.id) { @Sendable row in
                row.content
            }
        }
    }

    private func selectionButton(_ item: ActionProposal.Item, isCompleted: Bool, isSelected: Bool) -> some View {
        Button {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } label: {
            HStack(spacing: Layout.spacing) {
                VStack(alignment: .leading) {
                    Text(item.title)
                    if let summary = item.summary {
                        Text(summary).font(font(Constants.Typography.subtextXXS, fallback: .caption)).foregroundStyle(secondaryForeground)
                    }
                    if isCompleted { Text("Applied").font(font(Constants.Typography.subtextXXS, fallback: .caption)) }
                }
                Spacer(minLength: 0)
                ProposalSelectionSwitch(isOn: isSelected)
            }
            .frame(minHeight: Layout.minimumRowHeight)
            .contentShape(Rectangle())
            .copyContextMenuPassthrough()
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isSelected ? "On" : "Off")
        .accessibilityIdentifier("proposal.item.\(item.id)")
    }

    private func actionButtons(_ store: ProposalActionStore) -> some View {
        Group {
            if usesWorkspaceDesign, dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Layout.spacing) { actionButtonContent(store) }
            } else {
                HStack { actionButtonContent(store) }
            }
        }
        .disabled(store.isBusy)
    }

    @ViewBuilder
    private func actionButtonContent(_ store: ProposalActionStore) -> some View {
        Button {
            confirmingDismiss = true
        } label: {
            Text("Not now")
                .copyContextMenuPassthrough()
        }
        .buttonStyle(IntentButtonStyle(variant: .secondary))
        .accessibilityIdentifier("proposal.dismiss")
        if !usesWorkspaceDesign || !dynamicTypeSize.isAccessibilitySize { Spacer() }
        if proposal.method != nil {
            Button {
                Task { await store.apply(proposal, messageId: messageId, selection: selection) }
            } label: {
                Text(proposal.method == "workspace.delete" ? "Delete" : "Archive")
                    .copyContextMenuPassthrough()
            }
            .buttonStyle(IntentButtonStyle())
            .disabled(selection.isEmpty)
            .accessibilityIdentifier("proposal.apply")
        }
        if store.isBusy { ProgressView() }
    }
}

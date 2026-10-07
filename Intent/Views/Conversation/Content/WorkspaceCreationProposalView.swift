import SwiftUI

struct WorkspaceCreationProposalView: View {
    let proposal: ActionProposal
    let creation: WorkspaceCreationProposal
    let store: ProposalActionStore
    let messageId: String
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var edits: WorkspaceProposalEdits
    @State private var confirmingDismiss = false

    private enum Layout {
        static let spacing: CGFloat = 12
        static let maximumPromptLines = 6
    }

    init(proposal: ActionProposal, creation: WorkspaceCreationProposal, store: ProposalActionStore, messageId: String) {
        self.proposal = proposal
        self.creation = creation
        self.store = store
        self.messageId = messageId
        _edits = State(initialValue: store.submittedEdits(proposal, messageId: messageId) ?? creation.edits)
    }

    private var workspace: Workspace? { store.createdWorkspaces[store.receiptKey(proposal, messageId: messageId)] }
    private var hasAttempt: Bool { store.hasCreationAttempt(proposal, messageId: messageId) }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            if store.isPending(proposal, messageId: messageId) {
                reviewFields
                ForEach(proposal.preview.warnings, id: \.self) { warning in
                    Text(warning).font(.callout)
                }
                if let error = store.errors[proposal.id] {
                    Text(error).foregroundStyle(Theme.destructive(for: colorScheme))
                        .accessibilityIdentifier("proposal.error")
                }
                actions
            } else if let outcome = store.resolutions[proposal.id] {
                Text(outcome == "applied" ? "Workspace created" : "Dismissed")
                    .accessibilityIdentifier("proposal.outcome")
                if outcome == "dismissed", workspace != nil {
                    Text("The workspace was created before the proposal was dismissed.")
                }
            } else if let error = store.loadError {
                Text(error)
                Button("Retry") { Task { await store.refresh() } }
                    .buttonStyle(IntentButtonStyle(variant: .secondary))
            } else {
                Text("Waiting for confirmation availability…")
            }
            if let workspace {
                Button {
                    coordinator.onSelectWorkspace(workspace.id)
                } label: {
                    Text("Open workspace").copyContextMenuPassthrough()
                }
                .buttonStyle(IntentButtonStyle(variant: .secondary))
                .accessibilityIdentifier("proposal.openWorkspace")
            }
        }
        .confirmationDialog("Dismiss this proposal?", isPresented: $confirmingDismiss, titleVisibility: .visible) {
            Button("Dismiss proposal", role: .destructive) {
                Task { await store.dismiss(proposal, messageId: messageId) }
            }
        } message: {
            Text("The agent will be told that you dismissed it.")
        }
    }

    private var reviewFields: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            LabeledContent("Repository", value: creation.repository)
            LabeledContent("Base branch", value: creation.branch ?? "Repository default")
            if let specialist = creation.specialist { LabeledContent("Specialist", value: specialist) }
            VStack(alignment: .leading) {
                Text("Workspace title").font(.caption).foregroundStyle(.secondary)
                TextField("Name automatically", text: $edits.title, axis: .vertical)
                    .accessibilityLabel("Workspace title")
                    .accessibilityIdentifier("proposal.workspaceTitle")
            }
            VStack(alignment: .leading) {
                Text("Instructions").font(.caption).foregroundStyle(.secondary)
                TextField("What should the agent work on?", text: $edits.initialPrompt, axis: .vertical)
                    .lineLimit(2...Layout.maximumPromptLines)
                    .accessibilityLabel("Instructions")
                    .accessibilityIdentifier("proposal.initialPrompt")
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(store.isBusy || hasAttempt)
    }

    private var actions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
        return layout {
            if !hasAttempt {
                Button {
                    confirmingDismiss = true
                } label: {
                    Text("Not now").copyContextMenuPassthrough()
                }
                .buttonStyle(IntentButtonStyle(variant: .secondary))
                .accessibilityIdentifier("proposal.dismiss")
            }
            Button {
                Task { await store.createWorkspace(proposal, messageId: messageId, edits: edits) }
            } label: {
                Text(store.isBusy ? "Creating…" : hasAttempt ? "Retry" : "Create workspace").copyContextMenuPassthrough()
            }
            .buttonStyle(IntentButtonStyle())
            .disabled(!store.canCreateWorkspace)
            .accessibilityIdentifier("proposal.apply")
            if store.isBusy { ProgressView("Creating workspace…") }
        }
        .disabled(store.isBusy)
    }
}

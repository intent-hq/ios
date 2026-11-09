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
    @State private var activeCreationAction: CreationAction?

    private enum CreationAction: String {
        case create = "Create"
        case retry = "Retry"
    }

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
    private var actionTitle: String { (activeCreationAction ?? (hasAttempt ? .retry : .create)).rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            statusContent
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
            .disabledWhileReadOnly()
        } message: {
            Text("The agent will be told that you dismissed it.")
        }
    }

    @ViewBuilder
    private var statusContent: some View {
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
            Button {
                Task { await store.refresh() }
            } label: {
                Text("Retry").copyContextMenuPassthrough()
            }
            .buttonStyle(IntentButtonStyle(variant: .secondary))
        } else {
            Text("Waiting for confirmation availability…")
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
            if !hasAttempt || activeCreationAction == .create {
                Button {
                    confirmingDismiss = true
                } label: {
                    Text("Not now").copyContextMenuPassthrough()
                }
                .buttonStyle(IntentButtonStyle(variant: .secondary))
                .requiresLiveConnection()
                .accessibilityIdentifier("proposal.dismiss")
            }
            Button {
                guard activeCreationAction == nil else { return }
                activeCreationAction = hasAttempt ? .retry : .create
                Task {
                    defer { activeCreationAction = nil }
                    await store.createWorkspace(proposal, messageId: messageId, edits: edits)
                }
            } label: {
                Text(actionTitle)
                    .copyContextMenuPassthrough()
                    .opacity(activeCreationAction == nil ? 1 : 0)
                    .overlay {
                        if activeCreationAction != nil { ProgressView().accessibilityHidden(true) }
                    }
            }
            .buttonStyle(IntentButtonStyle())
            .disabled(!store.canCreateWorkspace)
            .requiresLiveConnection()
            .accessibilityLabel(activeCreationAction != nil ? "Creating workspace" : actionTitle)
            .accessibilityIdentifier("proposal.apply")
        }
        .disabled(store.isBusy || activeCreationAction != nil)
    }
}

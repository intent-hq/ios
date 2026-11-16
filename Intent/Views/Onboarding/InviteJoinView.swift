import SwiftUI

/// Sheet for an `intent://invite` link: someone shared a workspace with this
/// person. Nothing is sent to the host beyond reading the invite's preview
/// until the person taps Join (see InviteJoinModel for the flow).
struct InviteJoinView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(BackendSession.self) private var session
    let link: InviteLink
    @State private var model: InviteJoinModel?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Join Workspace")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        IntentIconButton(icon: .close, label: "Cancel", action: close)
                    }
                    .intentToolbarSurface()
                }
        }
        .task {
            guard model == nil else { return }
            let created = InviteJoinModel(link: link, environment: coordinator.inviteJoinEnvironment(connection: session.connection))
            model = created
            created.start()
        }
        .onChange(of: model?.phase) { _, phase in
            if phase == .finished { coordinator.pendingDeepLink = nil }
        }
        .onDisappear { model?.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch model?.phase ?? .connecting {
        case .connecting:
            InviteJoinProgress(text: "Connecting to the shared host…")
        case .joining:
            InviteJoinProgress(text: "Joining…")
        case .finished:
            InviteJoinProgress(text: "Opening the workspace…")
        case .confirm(let confirmation):
            InviteJoinConfirmView(confirmation: confirmation) { model?.answer(true) }
        case .needsOwnMac:
            InviteJoinMessageView(
                title: "Confirm Your Account on Your Mac",
                message: "To join, Intent needs to confirm your GitHub or GitLab account, and it does that through your own Mac. "
                    + "Open this link on your Mac, or pair this iPhone with your Mac and try again. "
                    + "Once you've joined on your Mac, the workspace appears here too.",
                link: link.url,
                retry: nil
            )
        case let .needsSignIn(providerName, macName):
            InviteJoinMessageView(
                title: "Sign In to \(providerName)",
                message: "\(macName) isn't signed in to \(providerName). Sign in to \(providerName) in Intent on that Mac, then try again.",
                link: nil
            ) { model?.start() }
        case .failed(let problem):
            InviteJoinMessageView(
                title: problem.title,
                message: problem.message,
                link: nil,
                retry: problem.retryable ? { model?.start() } : nil
            )
        }
    }

    private func close() {
        model?.cancel()
        coordinator.pendingDeepLink = nil
    }
}

private enum InviteJoinLayout {
    static let progressSpacing: CGFloat = 12
    static let titleSpacing: CGFloat = 4
    static let messageSpacing: CGFloat = 8
    static let rowPadding: CGFloat = 4
}

private struct InviteJoinProgress: View {
    let text: String

    var body: some View {
        VStack(spacing: InviteJoinLayout.progressSpacing) {
            ProgressView()
            Text(text)
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("invite-join-progress")
    }
}

private struct InviteJoinConfirmView: View {
    let confirmation: InviteJoinConfirmation
    let join: () -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: InviteJoinLayout.titleSpacing) {
                    Text(confirmation.scope == .host ? confirmation.hostName : confirmation.workspaceTitle)
                        .interFont(Constants.Typography.bodyM)
                        .accessibilityIdentifier("invite-join-title")
                    Text(confirmation.scope == .host ? "Become a member of this host" : "Shared from \(confirmation.hostName)")
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, InviteJoinLayout.rowPadding)
            }
            Section {
                Text(explanation)
                    .interFont(Constants.Typography.bodyXS)
                    .accessibilityIdentifier("invite-join-explanation")
            }
            Section {
                Button(action: join) {
                    Text("Join as @\(confirmation.login)")
                        .interFont(Constants.Typography.bodySEmphasized)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(IntentButtonStyle())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("invite-join-button")
            } footer: {
                Text("Only join if you trust the person who shared this link. They'll see your account name.")
                    .interFont(Constants.Typography.subtextXXS)
            }
        }
    }

    private var explanation: String {
        switch confirmation.method {
        case .existingAccess:
            return "You'll join with the access this device already has for \(confirmation.hostName)."
        case let .proveOnMac(macName, providerName):
            let proof = providerName == "GitHub" ? "a secret gist" : "a snippet"
            return "To confirm you're @\(confirmation.login) on \(providerName), Intent on \(macName) will briefly publish \(proof) "
                + "for the host to check, then delete it."
        }
    }
}

private struct InviteJoinMessageView: View {
    let title: String
    let message: String
    let link: URL?
    let retry: (() -> Void)?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: InviteJoinLayout.messageSpacing) {
                    Text(title)
                        .interFont(Constants.Typography.bodyM)
                        .accessibilityIdentifier("invite-join-message-title")
                    Text(message)
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, InviteJoinLayout.rowPadding)
            }
            if let retry {
                Section { retryButton(retry) }
            }
            if let link {
                Section { copyButton(link) }
            }
        }
    }

    private func retryButton(_ retry: @escaping () -> Void) -> some View {
        Button(action: retry) {
            Text("Try Again")
                .interFont(Constants.Typography.bodySEmphasized)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(IntentButtonStyle())
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .accessibilityIdentifier("invite-join-retry")
    }

    private func copyButton(_ link: URL) -> some View {
        Button {
            UIPasteboard.general.url = link
            HapticManager.notification(.success)
        } label: {
            Text("Copy Link")
                .interFont(Constants.Typography.bodySEmphasized)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(IntentButtonStyle(variant: .secondary))
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .accessibilityIdentifier("invite-join-copy-link")
    }
}

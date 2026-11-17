import SwiftUI

/// Opens the Share sheet for one workspace.
struct ShareWorkspaceRequest: Identifiable, Equatable {
    let workspaceId: String

    var id: String { workspaceId }
}

/// Share sheet: create an invite link (for anyone, or for one GitHub account)
/// and send it. People only join by opening a link; members and open links
/// are managed in Intent on the Mac.
struct ShareWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: WorkspaceSharingModel

    init(model: WorkspaceSharingModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ShareLayout.sectionSpacing) {
                    if case .created(let url) = model.phase {
                        ShareCreatedLink(url: url)
                    } else {
                        ShareLinkForm(model: model)
                    }
                    Text("To remove people or turn off a link, use Intent on your Mac.")
                        .interFont(Constants.Typography.subtextXXS)
                        .foregroundStyle(.secondary)
                }
                .padding(ShareLayout.padding)
            }
            .accessibilityIdentifier("share-workspace")
            .navigationTitle("Share Workspace")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    IntentIconButton(icon: .close, label: "Close") { dismiss() }
                }
                .intentToolbarSurface()
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Who can use the link, and the button that creates it.
private struct ShareLinkForm: View {
    @Bindable var model: WorkspaceSharingModel

    var body: some View {
        VStack(alignment: .leading, spacing: ShareLayout.itemSpacing) {
            Picker("Who can join", selection: $model.audience) {
                Text("Anyone with the link").tag(WorkspaceSharingModel.Audience.anyone)
                Text("One person").tag(WorkspaceSharingModel.Audience.person)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("share-audience")
            if model.audience == .person {
                TextField("GitHub username", text: $model.pinLogin)
                    .interFont(Constants.Typography.bodyS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("share-pin-login")
            }
            Text(footer)
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .failed(let message) = model.phase {
                Text(message)
                    .interFont(Constants.Typography.bodyS)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("share-error")
            }
            createButton
        }
    }

    private var createButton: some View {
        Button {
            Task { await model.createLink() }
        } label: {
            HStack {
                if model.phase == .creating { ProgressView() }
                Text(model.phase == .creating ? "Creating…" : "Create Invite Link")
                    .interFont(Constants.Typography.bodySEmphasized)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(IntentButtonStyle())
        .disabled(!model.canCreate)
        .accessibilityIdentifier("share-create-link")
    }

    private var footer: String {
        model.audience == .anyone
            ? "Anyone with the link can join until it expires."
            : "Only this GitHub account can use the link, once."
    }
}

/// The new link, sent through the system share sheet (which also copies it).
private struct ShareCreatedLink: View {
    let url: URL

    var body: some View {
        ShareLink(item: url, message: Text("Join my workspace in Intent")) {
            Label { Text("Send Invite Link").interFont(Constants.Typography.bodySEmphasized) } icon: { Image(.upload) }
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(IntentButtonStyle())
        .accessibilityIdentifier("share-invite-send")
    }
}

private enum ShareLayout {
    static let padding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let itemSpacing: CGFloat = 12
}

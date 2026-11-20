import SwiftUI

struct ShareWorkspaceRequest: Identifiable, Equatable {
    let workspaceId: String

    var id: String { workspaceId }
}

struct ShareWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: WorkspaceSharingModel
    @State private var contentHeight: CGFloat = 0

    init(model: WorkspaceSharingModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: ShareLayout.sectionSpacing) {
            header
            if case .created(let link) = model.phase {
                ShareCreatedLink(link: link)
            } else {
                ShareLinkForm(model: model)
            }
        }
        .padding(.horizontal, ShareLayout.padding)
        .padding(.top, ShareLayout.topPadding)
        .padding(.bottom, ShareLayout.bottomPadding)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share-workspace")
        .presentationDetents([.height(contentHeight > 0 ? contentHeight : ShareLayout.initialHeight)])
    }

    private var header: some View {
        ZStack {
            Text("Share Workspace")
                .interFont(Constants.Typography.bodySEmphasized)
                .accessibilityAddTraits(.isHeader)
            HStack {
                IntentIconButton(icon: .close, label: "Close") { dismiss() }
                Spacer()
            }
        }
    }
}

private struct ShareLinkForm: View {
    @Bindable var model: WorkspaceSharingModel

    var body: some View {
        VStack(spacing: ShareLayout.itemSpacing) {
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
            createButton
            if case .failed(let message) = model.phase {
                Text(message)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("share-error")
            }
            ShareCaption(text: caption)
        }
    }

    private var createButton: some View {
        Button {
            Task { await model.createLink() }
        } label: {
            HStack {
                if model.phase == .creating { ProgressView() }
                Text(model.phase == .creating ? "Creating…" : "Create Link")
                    .interFont(Constants.Typography.bodySEmphasized)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(IntentButtonStyle())
        .disabled(!model.canCreate)
        .accessibilityIdentifier("share-create-link")
    }

    private var caption: String {
        model.audience == .anyone
            ? "Anyone with the link can join until it expires."
            : "Only this GitHub account can use the link, once."
    }
}

private struct ShareCreatedLink: View {
    let link: WorkspaceSharingModel.InviteLink
    @State private var copied = false

    var body: some View {
        VStack(spacing: ShareLayout.itemSpacing) {
            ShareLink(item: link.url, message: Text("Join my workspace in Intent")) {
                Text("Send Link")
                    .interFont(Constants.Typography.bodySEmphasized)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(IntentButtonStyle())
            .accessibilityIdentifier("share-invite-send")
            Button {
                UIPasteboard.general.url = link.url
                HapticManager.notification(.success)
                copied = true
            } label: {
                Text(copied ? "Copied" : "Copy Link")
                    .interFont(Constants.Typography.bodySEmphasized)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(IntentButtonStyle(variant: .secondary))
            .accessibilityIdentifier("share-invite-copy")
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: ShareLayout.copiedDuration)
                copied = false
            }
            ShareCaption(text: caption)
                .accessibilityIdentifier("share-invite-summary")
        }
    }

    private var caption: String {
        let who = link.pinLogin.map { "Only @\($0) can use this link, once." } ?? "Anyone with the link can join."
        guard let expiresAt = link.expiresAt else { return who }
        return "\(who) \(WorkspaceSharingModel.expiryText(expiresAt))"
    }
}

private struct ShareCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .interFont(Constants.Typography.subtextXXS)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
}

private enum ShareLayout {
    static let padding: CGFloat = 20
    static let topPadding: CGFloat = 16
    static let bottomPadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 20
    static let itemSpacing: CGFloat = 12
    static let initialHeight: CGFloat = 280
    static let copiedDuration: Duration = .seconds(2)
}

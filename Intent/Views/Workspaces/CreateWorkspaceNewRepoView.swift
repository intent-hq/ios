import SwiftUI

struct CreateWorkspaceNewRepoView: View {
    @Binding var draft: NewRepositoryDraft
    let connection: any SessionConnectionManaging
    let attempt: NewRepositoryAttempt?
    let onBack: () -> Void
    let onNext: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isChecking = false
    @State private var destinationError: String?
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            CreateWorkspaceSelectionHeader(
                leadingControl: .back,
                isNextDisabled: draft.repositoryPath == nil || isChecking,
                onLeadingAction: onBack,
                onNext: checkDestination
            )
            .disabled(isChecking)
            CreateWorkspaceSelectionPage(title: "New Repository", titleIdentifier: "creation.newRepositoryTitle") {
                VStack(alignment: .leading, spacing: CreateWorkspaceFormStyle.sectionSpacing) {
                    Text("Create a Git repository on your connected computer. You can publish it to GitHub later.")
                        .interFont(Constants.Typography.bodyS)
                    field("Repository name", placeholder: "my-project", text: $draft.name, identifier: "creation.newRepositoryName")
                    field("Parent folder", placeholder: "~/Developer", text: $draft.parentPath, identifier: "creation.newRepositoryParent")
                    if let path = draft.repositoryPath {
                        Text(path)
                            .interFont(Constants.Typography.bodyS)
                            .accessibilityIdentifier("creation.newRepositoryPath")
                    }
                    if let error = destinationError ?? (draft.name.isEmpty ? nil : draft.validationError) {
                        Text(error)
                            .interFont(Constants.Typography.bodyS)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("creation.newRepositoryError")
                    }
                    if isChecking {
                        ProgressView("Checking folder...")
                    }
                }
                .disabled(isChecking)
            }
        }
        .background(CreateWorkspaceRepoStyle.background(for: colorScheme).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .interactiveDismissDisabled(isChecking)
        .onChange(of: draft) { _, _ in destinationError = nil }
        .onDisappear {
            checkTask?.cancel()
            isChecking = false
        }
    }

    private func field(_ title: LocalizedStringKey, placeholder: LocalizedStringKey, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: CreateWorkspaceFormStyle.rowSpacing) {
            Text(title).interFont(Constants.Typography.bodySEmphasized)
            TextField(placeholder, text: text)
                .interFont(Constants.Typography.bodyS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(CreateWorkspaceFormStyle.controlPadding)
                .background(CreateWorkspaceRepoStyle.card(for: colorScheme), in: .rect(
                    cornerRadius: CreateWorkspaceFormStyle.cornerRadius
                ))
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
    }

    private func checkDestination() {
        guard !isChecking, let path = draft.repositoryPath else { return }
        if attempt?.retryKey(for: path) != nil {
            onNext(path)
            return
        }
        isChecking = true
        destinationError = nil
        checkTask = Task {
            defer { if !Task.isCancelled { isChecking = false } }
            do {
                let response = try await connection.request("host.directoryStatus", params: ["path": path])
                guard !Task.isCancelled, draft.repositoryPath == path else { return }
                if let error = NewRepositoryDraft.destinationError(for: response) {
                    destinationError = error
                } else {
                    onNext(path)
                }
            } catch {
                guard !Task.isCancelled else { return }
                destinationError = error.localizedDescription
            }
        }
    }
}

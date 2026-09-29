import SwiftUI

struct CreateWorkspaceRepoStepView: View {
    var store: GitHubRepoStore
    @Binding var selectedRepo: GitHubRepo?
    let onClose: () -> Void
    let onNext: () -> Void
    let onRepoChanged: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            CreateWorkspaceRepoHeader(isNextDisabled: selectedRepo == nil, onClose: onClose, onNext: onNext)
            GitHubRepoPickerView(store: store, selectedRepo: $selectedRepo)
        }
        .background(CreateWorkspaceRepoStyle.background(for: colorScheme).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: selectedRepo?.id) { _, _ in
            onRepoChanged()
        }
    }
}

private struct CreateWorkspaceRepoHeader: View {
    let isNextDisabled: Bool
    let onClose: () -> Void
    let onNext: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .title3) private var iconSize = CreateWorkspaceRepoStyle.iconSize

    var body: some View {
        HStack {
            Button(action: onClose) {
                Image(.close)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .frame(minWidth: CreateWorkspaceFormStyle.controlHeight, minHeight: CreateWorkspaceFormStyle.controlHeight)
                    .contentShape(.rect)
            }
            .foregroundStyle(CreateWorkspaceRepoStyle.foreground(for: colorScheme))
            .accessibilityLabel("Close")
            .accessibilityIdentifier("creation.close")
            Spacer()
            Button(action: onNext) {
                Text("Next")
                    .interFont(Constants.Typography.bodySEmphasized)
                    .padding(.horizontal, CreateWorkspaceFormStyle.controlPadding)
                    .padding(.vertical, CreateWorkspaceFormStyle.controlVerticalPadding)
                    .frame(minHeight: CreateWorkspaceFormStyle.controlHeight)
                    .foregroundStyle(CreateWorkspaceRepoStyle.foreground(for: colorScheme))
                    .background(CreateWorkspaceRepoStyle.card(for: colorScheme), in: .rect(
                        cornerRadius: CreateWorkspaceFormStyle.cornerRadius
                    ))
                    .opacity(isNextDisabled ? 0.5 : 1)
            }
            .disabled(isNextDisabled)
        }
        .buttonStyle(.plain)
        .padding(CreateWorkspaceFormStyle.pagePadding)
    }
}

import SwiftUI

struct LoadFailureView: View {
    let subject: String
    let message: String
    let identifier: String
    var isCompact = false
    let retry: @MainActor () async -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .availableWhenReconnected(isMissing: true, isCompact: isCompact)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(identifier).loadFailure")
    }

    @ViewBuilder
    private var content: some View {
        if isCompact {
            VStack(alignment: .leading, spacing: WorkspaceDetailStyle.headingSpacing) {
                Text("Couldn't Load \(subject)").interFont(Constants.Typography.bodyS.withFace(.semibold))
                Text(message)
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                retryButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView {
                Label {
                    Text("Couldn't Load \(subject)").interFont(Constants.Typography.bodyM.withFace(.semibold))
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(message).interFont(Constants.Typography.bodyS)
            } actions: {
                retryButton
            }
            .frame(maxWidth: .infinity, minHeight: Constants.WorkspaceList.emptyStateHeight)
        }
    }

    private var retryButton: some View {
        Button("Retry") { Task { await retry() } }
            .buttonStyle(IntentButtonStyle(variant: .secondary))
            .disabledWhileReadOnly()
            .accessibilityIdentifier("\(identifier).loadFailure.retry")
    }
}

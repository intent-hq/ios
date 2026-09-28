import SwiftUI

/// App-owned navigation inside the native top safe area; no status-bar geometry.
struct WorkspaceConversationHeader<Actions: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onBack) {
                Image(systemName: "arrow.left")
                    .font(.system(size: Design.iconSize))
                    .frame(width: Design.Header.controlSize, height: Design.Header.controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("conversation.back")
            VStack(spacing: Design.Header.titleSpacing) {
                Text(title)
                    .interFont(Constants.Typography.bodyXSEmphasized)
                    .lineLimit(1)
                Text("Agent")
                    .interFont(Constants.Typography.bodyXS)
                    .foregroundStyle(Design.Palette.subtitleForeground(for: colorScheme, contrast: contrast))
            }
            .tracking(Design.Typography.smallTracking)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            actions()
        }
        .foregroundStyle(Design.Palette.foreground(for: colorScheme))
        .padding(.horizontal, Design.horizontalInset)
        .padding(.vertical, Design.Header.verticalPadding)
        .background(Design.Palette.background(for: colorScheme))
    }
}

struct WorkspaceGoToEndLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    private typealias Design = Constants.Conversation.Design

    var body: some View {
        HStack(spacing: Design.Status.goToEndIconSpacing) {
            Image(systemName: "arrow.down")
                .font(.system(size: Design.smallIconSize))
                .opacity(Design.Status.goToEndIconOpacity)
                .accessibilityHidden(true)
            Text("Go To End")
                .interFont(Design.Typography.status)
        }
        .foregroundStyle(Design.Palette.foreground(for: colorScheme))
        .padding(.leading, Design.Status.goToEndLeadingPadding)
        .padding(.trailing, Design.Status.goToEndTrailingPadding)
        .frame(minHeight: Design.Status.minimumHeight)
        .background(Design.Palette.surface(for: colorScheme), in: Capsule())
        .frame(minHeight: Design.minimumTapTarget)
        .contentShape(Rectangle())
    }
}

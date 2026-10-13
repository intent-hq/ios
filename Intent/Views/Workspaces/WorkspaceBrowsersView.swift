import SwiftUI

struct WorkspaceBrowsersView: View {
    let workspaceId: String
    let store: WorkspaceBrowserStore
    @Binding var revealedTarget: WorkspaceSwipeTarget?
    let onSelect: (WorkspaceBrowser) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let browsers = store.browsers(workspaceId: workspaceId)
        if !browsers.isEmpty || store.errorMessage(workspaceId: workspaceId) != nil {
            VStack(alignment: .leading, spacing: WorkspaceDetailStyle.sectionHeadingSpacing) {
                Text("Browsers")
                    .interFont(Constants.Typography.eyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast))
                    .accessibilityAddTraits(.isHeader)
                LazyVStack(spacing: WorkspaceDetailStyle.rowSpacing) {
                    ForEach(browsers) { browser in
                        WorkspaceBrowserRow(browser: browser, store: store, revealedTarget: $revealedTarget, onSelect: onSelect)
                    }
                }
                .padding(.horizontal, -WorkspaceDetailStyle.pageInset)
                if let error = store.errorMessage(workspaceId: workspaceId) {
                    VStack(alignment: .leading) {
                        Text(error).interFont(Constants.Typography.bodyXS)
                        Button("Retry") {
                            Task { await store.refresh(workspaceId: workspaceId) }
                        }
                        .buttonStyle(IntentButtonStyle(variant: .secondary))
                        .disabled(!store.isConnected)
                    }
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct WorkspaceBrowserRow: View {
    @ScaledMetric(relativeTo: .title2) private var iconSize = WorkspaceDetailStyle.iconSize
    @ScaledMetric(relativeTo: .caption) private var chevronSize = Constants.Typography.subtextXXS.size
    let browser: WorkspaceBrowser
    let store: WorkspaceBrowserStore
    @Binding var revealedTarget: WorkspaceSwipeTarget?
    let onSelect: (WorkspaceBrowser) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        WorkspaceSwipeContainer(
            target: .browser(browser.id),
            revealedTarget: $revealedTarget,
            actionCount: 1,
            horizontalInset: WorkspaceDetailStyle.pageInset
        ) { progress in
            browserButton(swipeProgress: progress)
        } actions: {
            deleteButton
        }
    }

    private func browserButton(swipeProgress: CGFloat) -> some View {
        Button {
            if revealedTarget != nil {
                revealedTarget = nil
            } else {
                onSelect(browser)
            }
        } label: {
            row(swipeProgress: swipeProgress)
        }
        .buttonStyle(BrowserRowButtonStyle())
        .visionListRowHitTarget()
        .accessibilityIdentifier("browser.row.\(browser.id)")
        .contextMenu {
            Button(role: .destructive) { store.remove(browser) } label: {
                Label { Text("Delete browser") } icon: { Image(.delete) }
            }
        }
        .accessibilityAction(named: "Delete browser") { store.remove(browser) }
    }

    private var deleteButton: some View {
        Button("Delete", role: .destructive) { store.remove(browser) }
            .buttonStyle(WorkspaceSwipeButtonStyle(color: .red))
            .accessibilityLabel("Delete browser")
            .accessibilityIdentifier("browser.delete.\(browser.id)")
    }

    private struct BrowserRowButtonStyle: PrimitiveButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .onTapGesture { configuration.trigger() }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { configuration.trigger() }
        }
    }

    private func row(swipeProgress: CGFloat) -> some View {
        HStack(alignment: .top, spacing: WorkspaceDetailStyle.avatarSpacing) {
            Image(.globe)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast))
                .frame(width: WorkspaceDetailStyle.avatarSize, height: WorkspaceDetailStyle.avatarSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WorkspaceDetailStyle.noteTitleSpacing) {
                Text(browser.title)
                    .interFont(Constants.Typography.bodyM)
                    .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
                if let command = browser.command {
                    Text(command)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                }
                Text(browser.url)
                    .interFont(Constants.Typography.bodyXS)
                    .lineLimit(1)
                if !store.isConnected {
                    Text("Disconnected").interFont(Constants.Typography.subtextXXS)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(.chevronRight)
                .resizable()
                .scaledToFit()
                .frame(width: chevronSize, height: chevronSize)
                .frame(height: WorkspaceDetailStyle.avatarSize)
                .opacity(1 - Double(swipeProgress))
                .accessibilityHidden(true)
        }
        .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast))
        .frame(minHeight: Constants.Accessibility.minimumTapTarget, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

enum BrowserAppearance {
    static let rowSpacing: CGFloat = 12
    static let rowPadding: CGFloat = 12
    static let labelSpacing: CGFloat = 4
    static let controlSize: CGFloat = 44
    static let cornerRadius: CGFloat = 18
    static let minimumDrag: CGFloat = 20
}

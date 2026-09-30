import SwiftUI

struct WorkspaceBrowsersView: View {
    let workspaceId: String
    let store: WorkspaceBrowserStore
    let onSelect: (WorkspaceBrowser) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let browsers = store.browsers(workspaceId: workspaceId)
        if !browsers.isEmpty || store.errorMessage(workspaceId: workspaceId) != nil {
            VStack(alignment: .leading, spacing: WorkspaceDetailStyle.sectionHeadingSpacing) {
                Text("Browsers")
                    .interFont(Constants.Typography.bodyM.withFace(.semibold))
                    .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
                    .accessibilityAddTraits(.isHeader)
                LazyVStack(spacing: WorkspaceDetailStyle.rowSpacing) {
                    ForEach(browsers) { browser in
                        WorkspaceBrowserRow(browser: browser, store: store, onSelect: onSelect)
                    }
                }
                if let error = store.errorMessage(workspaceId: workspaceId) {
                    VStack(alignment: .leading) {
                        Text(error).interFont(Constants.Typography.bodyXS)
                        Button("Retry") {
                            Task { await store.refresh(workspaceId: workspaceId) }
                        }
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
    let browser: WorkspaceBrowser
    let store: WorkspaceBrowserStore
    let onSelect: (WorkspaceBrowser) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isRevealed = false

    var body: some View {
        WorkspaceSwipeContainer(
            isRevealed: $isRevealed,
            actionCount: 1,
            rowBackground: Theme.card(for: colorScheme),
            restingCornerRadius: BrowserAppearance.cornerRadius
        ) { _ in
            browserButton
        } actions: {
            deleteButton
        }
    }

    private var browserButton: some View {
        Button {
            if isRevealed {
                isRevealed = false
            } else {
                onSelect(browser)
            }
        } label: {
            row
        }
        .buttonStyle(BrowserRowButtonStyle())
        .visionListRowHitTarget()
        .accessibilityIdentifier("browser.row.\(browser.id)")
        .contextMenu {
            Button("Delete browser", systemImage: "trash", role: .destructive) { store.remove(browser) }
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

    private var row: some View {
        HStack(spacing: BrowserAppearance.rowSpacing) {
            Image(systemName: "globe")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: BrowserAppearance.controlSize, height: BrowserAppearance.controlSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BrowserAppearance.labelSpacing) {
                Text(browser.title).interFont(Constants.Typography.bodyXS.withFace(.semibold))
                if let command = browser.command {
                    Text(command)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                }
                Text(browser.url)
                    .interFont(Constants.Typography.subtextXXS)
                    .lineLimit(1)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                if !store.isConnected {
                    Text("Disconnected").interFont(Constants.Typography.subtextXXS)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .accessibilityHidden(true)
        }
        .padding(BrowserAppearance.rowPadding)
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

import SwiftUI

struct WorkspaceBrowsersView: View {
    let workspaceId: String
    let store: WorkspaceBrowserStore
    let onSelect: (WorkspaceBrowser) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let browsers = store.browsers(workspaceId: workspaceId)
        if !browsers.isEmpty || store.errorMessage(workspaceId: workspaceId) != nil {
            Text("Browsers")
                .interFont(Constants.Typography.bodyM.withFace(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical)
            ForEach(browsers) { browser in
                Button { onSelect(browser) } label: { row(browser) }
                    .buttonStyle(.plain)
                    .visionListRowHitTarget()
                    .contextMenu {
                        if browser.isSavedSession {
                            Button("Remove browser", systemImage: "trash", role: .destructive) {
                                store.remove(browser)
                            }
                        }
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
                .padding(.vertical)
            }
        }
    }

    private func row(_ browser: WorkspaceBrowser) -> some View {
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
        .background(Theme.card(for: colorScheme), in: RoundedRectangle(cornerRadius: BrowserAppearance.cornerRadius))
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
}

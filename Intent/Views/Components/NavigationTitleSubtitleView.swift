import SwiftUI

enum WorkspaceSubtitleResolver {
    static func subtitle(forWorkspaceId workspaceId: String, in workspaces: [Workspace]) -> String? {
        guard let title = workspaces.first(where: { $0.id == workspaceId })?.title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return title
    }
}

struct NavigationTitleSubtitleView: View {
    let title: String
    let subtitle: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        #if os(visionOS)
        titleStack(alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        #else
        titleStack(alignment: .center)
        #endif
    }

    private func titleStack(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(title)
                .interFont(Constants.Typography.bodyM.withFace(.semibold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(subtitle)
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

struct WorkspaceNavigationSubtitleModifier: ViewModifier {
    let title: String
    let workspaceId: String
    @Environment(BackendSession.self) private var session

    private var subtitle: String? {
        WorkspaceSubtitleResolver.subtitle(
            forWorkspaceId: workspaceId,
            in: session.workspaceStore.workspaces
        )
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(visionOS)
        fallbackBody(content: content)
        #else
        if #available(iOS 26.0, *) {
            content
                .navigationSubtitle(subtitle ?? "")
                .task { await fetchWorkspacesIfNeeded() }
        } else {
            fallbackBody(content: content)
        }
        #endif
    }

    private func fallbackBody(content: Content) -> some View {
        content
            .toolbar {
                if let subtitle {
                    ToolbarItem(placement: .principal) {
                        NavigationTitleSubtitleView(title: title, subtitle: subtitle)
                    }
                }
            }
            .task { await fetchWorkspacesIfNeeded() }
    }

    private func fetchWorkspacesIfNeeded() async {
        await session.workspaceStore.fetchIfNeeded()
    }
}

extension View {
    func workspaceNavigationSubtitle(title: String, workspaceId: String) -> some View {
        modifier(WorkspaceNavigationSubtitleModifier(title: title, workspaceId: workspaceId))
    }
}

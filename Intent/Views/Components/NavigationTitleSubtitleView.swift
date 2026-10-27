import SwiftUI

/// Resolves the workspace-name subtitle shown beneath navigation titles.
enum WorkspaceSubtitleResolver {
    /// Returns the title of the workspace with `workspaceId`, or nil when the
    /// workspace is unknown or its title is blank — callers hide the subtitle
    /// entirely in that case (never a placeholder).
    static func subtitle(forWorkspaceId workspaceId: String, in workspaces: [Workspace]) -> String? {
        guard let title = workspaces.first(where: { $0.id == workspaceId })?.title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return title
    }
}

/// Fallback (iOS 18–25) principal toolbar item: the navigation title stacked
/// over the workspace-name subtitle, both truncating long values.
struct NavigationTitleSubtitleView: View {
    let title: String
    let subtitle: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        #if os(visionOS)
        // The principal item sits leading-aligned next to the back button on
        // visionOS; left-align the two lines so they start on the same x.
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

/// Shows the workspace title as a subtitle beneath the navigation title.
/// On iOS 26+ this uses the native `.navigationSubtitle`; earlier releases
/// fall back to a `.principal` toolbar item that visually replaces the inline
/// title (the `.navigationTitle` set by the view stays in place on both paths
/// for back-button labels and accessibility).
struct WorkspaceNavigationSubtitleModifier: ViewModifier {
    /// The navigation title the fallback principal item re-renders.
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
        // `.navigationSubtitle` is unavailable on visionOS; always use the
        // principal-toolbar-item fallback there.
        fallbackBody(content: content)
        #else
        if #available(iOS 26.0, *) {
            // Never branch on the subtitle: the unfolded Duo's vertical-bar trait flips
            // while typing, and swapping branches would remount the focused composer.
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

    /// Cold start / deep link: the store may not have fetched yet.
    private func fetchWorkspacesIfNeeded() async {
        await session.workspaceStore.fetchIfNeeded()
    }
}

extension View {
    /// Adds a workspace-name subtitle beneath the navigation title; `title`
    /// must match the view's `.navigationTitle` (re-rendered by the pre-iOS 26
    /// fallback's principal toolbar item).
    func workspaceNavigationSubtitle(title: String, workspaceId: String) -> some View {
        modifier(WorkspaceNavigationSubtitleModifier(title: title, workspaceId: workspaceId))
    }
}

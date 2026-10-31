import SwiftUI

/// One pull request file's diff on its own page, under the pull request
/// page's header: back, the file name with its folder, and no actions.
struct PullRequestFileDiffPage: View {
    let file: PullRequestFile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var name: String { file.filename.split(separator: "/").last.map(String.init) ?? file.filename }
    private var folder: String { file.filename.split(separator: "/").dropLast().joined(separator: "/") }

    var body: some View {
        WorkspaceFileDiffView(loader: nil, path: file.filename, isBinary: file.patch == nil, patch: file.patch, showsPath: false)
            .background(WorkspaceDetailStyle.background(for: colorScheme))
            .safeAreaInset(edge: .top, spacing: 0) {
                WorkspaceNavigationHeader(
                    title: name,
                    subtitle: folder.isEmpty ? nil : LocalizedStringKey(folder),
                    backLabel: "Back to pull request",
                    backIdentifier: "pullRequest.file.back",
                    usesConversationLayout: true,
                    onBack: { dismiss() },
                    actions: {
                        Color.clear
                            .frame(width: WorkspaceDetailStyle.controlSize, height: WorkspaceDetailStyle.controlSize)
                            .accessibilityHidden(true)
                    }
                )
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden()
            .nativeNavigationBackGesture()
            .accessibilityAction(.escape) { dismiss() }
    }
}

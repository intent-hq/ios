import SwiftUI

struct TextLinkPreviewView: View {
    struct Link: Identifiable, Equatable {
        let workspaceId: String
        let path: String
        var id: String { "\(workspaceId)\u{0}\(path)" }
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    let link: Link
    @Environment(BackendSession.self) private var session: BackendSession?
    @Environment(\.dismiss) private var dismiss
    @State private var file: WorkspaceTextFile?
    @State private var hasFailed = false
    @State private var attempt = 0
    @ScaledMetric(relativeTo: .body) private var closeIconSide: CGFloat = 17

    private var fileLoader: WorkspaceFileImageLoader {
        session?.workspaceFileImageLoader ?? .shared
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(link.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        closeButton
                    }
                    if let file {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: file.url) {
                                Label("Share text file", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(IntentContentButtonStyle())
                        }
                    }
                }
                .accessibilityAction(.escape) { dismiss() }
        }
        .task(id: attempt) { await loadText() }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(.close)
                .resizable()
                .scaledToFit()
                .frame(width: closeIconSide, height: closeIconSide)
                .foregroundStyle(.white)
                .padding(Constants.Conversation.ImageLightbox.actionButtonPadding)
                .background(.black, in: Circle())
                .frame(
                    minWidth: Constants.Accessibility.minimumTapTarget,
                    minHeight: Constants.Accessibility.minimumTapTarget
                )
                .contentShape(.rect)
                .accessibilityHidden(true)
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Close text file")
        .accessibilityIdentifier("text.close")
    }

    @ViewBuilder
    private var content: some View {
        if let file {
            WorkspaceTextFileView(file: file)
        } else if hasFailed {
            ContentUnavailableView {
                Label("Text file unavailable", systemImage: "doc.text")
            } description: {
                Text("Could not load this file. Check your connection and use a UTF-8 text file no larger than 5 MiB.")
            } actions: {
                Button("Retry") {
                    fileLoader.forgetFailure(workspaceId: link.workspaceId, path: link.path)
                    attempt += 1
                }
                .buttonStyle(IntentContentButtonStyle())
                .accessibilityLabel("Retry loading text file")
            }
        } else {
            ProgressView("Loading text file…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadText() async {
        hasFailed = false
        do {
            let loaded = try await fileLoader.text(workspaceId: link.workspaceId, path: link.path)
            try Task.checkCancellation()
            file = loaded
        } catch {
            guard !Task.isCancelled else { return }
            hasFailed = true
        }
    }
}

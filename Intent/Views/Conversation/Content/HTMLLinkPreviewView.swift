import SwiftUI
import WebKit

struct HTMLLinkPreviewView: View {
    typealias Link = TextLinkPreviewView.Link

    let link: Link
    @Environment(BackendSession.self) private var session: BackendSession?
    @Environment(\.dismiss) private var dismiss
    @State private var file: WorkspaceTextFile?
    @State private var rules: WKContentRuleList?
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
                                Label("Share HTML file", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(IntentContentButtonStyle())
                        }
                    }
                }
                .accessibilityAction(.escape) { dismiss() }
        }
        .task(id: attempt) { await loadHTML() }
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
        .accessibilityLabel("Close HTML file")
        .accessibilityIdentifier("html.close")
    }

    @ViewBuilder
    private var content: some View {
        if hasFailed {
            ContentUnavailableView {
                Label("HTML file unavailable", systemImage: "doc.text")
            } description: {
                Text("Could not open this file as HTML. This viewer supports UTF-8 text files up to 5 MiB, not binary files.")
            } actions: {
                Button("Retry") {
                    fileLoader.forgetFailure(workspaceId: link.workspaceId, path: link.path)
                    attempt += 1
                }
                .buttonStyle(IntentContentButtonStyle())
                .accessibilityLabel("Retry loading HTML file")
            }
        } else if let file, let rules {
            HTMLFileWebView(file: file, rules: rules) { hasFailed = true }
        } else {
            ProgressView("Loading HTML file…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadHTML() async {
        file = nil
        hasFailed = false
        do {
            let loaded = try await fileLoader.text(workspaceId: link.workspaceId, path: link.path)
            // Fail closed: never mount untrusted HTML without its resource blocker.
            let blocker = try await HTMLFileWebView.blockingRules()
            try Task.checkCancellation()
            rules = blocker
            file = loaded
        } catch {
            guard !Task.isCancelled else { return }
            hasFailed = true
        }
    }
}

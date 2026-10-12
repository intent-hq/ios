import SwiftUI

/// A link can be opened before its bytes are cached, unlike an inline PDF card.
struct PDFLinkPreviewView: View {
    struct Link: Identifiable, Equatable {
        let workspaceId: String
        let path: String
        var id: String { "\(workspaceId)\u{0}\(path)" }
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    let link: Link
    @Environment(BackendSession.self) private var session: BackendSession?
    @Environment(\.dismiss) private var dismiss
    @State private var pdf: WorkspacePDF?
    @State private var hasFailed = false
    @State private var attempt = 0
    @ScaledMetric(relativeTo: .body) private var closeIconSide: CGFloat = 17

    private var fileLoader: WorkspaceFileImageLoader {
        session?.workspaceFileImageLoader ?? .shared
    }

    var body: some View {
        Group {
            if let pdf {
                PDFLightboxView(pdf: pdf)
            } else {
                NavigationStack {
                    loadingContent
                        .navigationTitle(link.name)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                closeButton
                            }
                        }
                        .accessibilityAction(.escape) { dismiss() }
                }
            }
        }
        .task(id: attempt) { await loadPDF() }
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
        .accessibilityLabel("Close PDF")
        .accessibilityIdentifier("pdf.close")
    }

    @ViewBuilder
    private var loadingContent: some View {
        if hasFailed {
            ContentUnavailableView {
                Label("PDF unavailable", systemImage: "doc.richtext")
            } description: {
                Text("Could not load this PDF. Check your connection and try again.")
            } actions: {
                Button("Retry") {
                    fileLoader.forgetFailure(workspaceId: link.workspaceId, path: link.path)
                    attempt += 1
                }
                .buttonStyle(IntentContentButtonStyle())
                .accessibilityLabel("Retry loading PDF")
            }
        } else {
            ProgressView("Loading PDF…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadPDF() async {
        hasFailed = false
        do {
            let loaded = try await fileLoader.pdf(workspaceId: link.workspaceId, path: link.path)
            try Task.checkCancellation()
            pdf = loaded
        } catch {
            guard !Task.isCancelled else { return }
            hasFailed = true
        }
    }
}

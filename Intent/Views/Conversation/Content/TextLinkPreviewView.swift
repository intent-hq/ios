import SwiftUI

struct TextLinkPreviewView: View {
    struct Link: Identifiable, Equatable {
        let workspaceId: String
        let path: String
        var id: String { "\(workspaceId)\u{0}\(path)" }
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    let link: Link
    var loaderOverride: WorkspaceFileImageLoader?
    @Environment(BackendSession.self) private var session: BackendSession?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var file: WorkspaceTextFile?
    @State private var hasFailed = false
    @State private var attempt = 0
    @AppStorage("fileViewerWrapLines") private var wrapLines = true

    private var fileLoader: WorkspaceFileImageLoader {
        loaderOverride ?? session?.workspaceFileImageLoader ?? .shared
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(link.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.sidebar(for: colorScheme), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        backButton
                    }
                    .intentToolbarSurface()
                    ToolbarItem(placement: .topBarTrailing) {
                        fileMenu
                    }
                    .intentToolbarSurface()
                }
                .accessibilityAction(.escape) { dismiss() }
        }
        .task(id: attempt) { await loadText() }
    }

    private var backButton: some View {
        IntentIconButton(icon: .arrowLeft, label: "Back", showsBackground: false) {
            dismiss()
        }
        .accessibilityIdentifier("text.close")
    }

    private var fileMenu: some View {
        Menu {
            Toggle("Wrap lines", isOn: $wrapLines)
                .accessibilityIdentifier("text.wrap")
        } label: {
            ToolbarOverflowLabel()
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(file == nil)
        .accessibilityLabel("File options")
        .accessibilityIdentifier("text.options")
    }

    @ViewBuilder
    private var content: some View {
        if let file {
            WorkspaceTextFileView(file: file, wrapLines: wrapLines)
        } else if hasFailed {
            ContentUnavailableView {
                Label("Text file unavailable", systemImage: "doc.text")
            } description: {
                Text("Could not open this file as text. This viewer supports UTF-8 text files up to 5 MiB, not binary files.")
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

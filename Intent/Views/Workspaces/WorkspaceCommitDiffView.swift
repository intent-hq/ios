import SwiftUI

struct WorkspaceCommitDiffView: View {
    let loader: WorkspaceDiffLoader
    let commit: WorkspaceCommit
    @State private var files: [WorkspaceCommitFile] = []
    @State private var selectedPath = ""
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceChangesLayout.sectionSpacing) {
            VStack(alignment: .leading, spacing: WorkspaceChangesLayout.rowSpacing) {
                Text(commit.message).interFont(Constants.Typography.bodyM).textSelection(.enabled)
                Text("\(commit.author) · \(commit.hash.prefix(WorkspaceChangesLayout.shortHashLength))")
                    .interFont(Constants.Typography.subtextXXS).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            if isLoading {
                ProgressView("Loading commit…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Commit Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else if files.isEmpty {
                ContentUnavailableView("No Changed Files", systemImage: "doc.text")
            } else {
                Picker("File (\(files.count))", selection: $selectedPath) {
                    ForEach(files) { file in
                        Text("\(file.path) (+\(file.additions) −\(file.deletions))").tag(file.path)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)
                WorkspaceFileDiffView(loader: loader, path: selectedPath, commitHash: commit.hash)
                    .id(selectedPath)
            }
        }
        .navigationTitle("Commit Changes")
        .toolbarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            files = try await loader.commitFiles(hash: commit.hash)
            selectedPath = files.first?.path ?? ""
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

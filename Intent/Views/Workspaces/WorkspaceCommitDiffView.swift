import SwiftUI

struct WorkspaceCommitDiffView: View {
    let loader: WorkspaceDiffLoader
    let commit: WorkspaceCommit
    @State private var files: [WorkspaceCommitFile] = []
    @State private var selectedPath = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: CreateWorkspaceRepoStyle.sectionHeaderSpacing) {
            commitHeader
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
                filePicker
                WorkspaceFileDiffView(loader: loader, path: selectedPath, commitHash: commit.hash)
                    .id(selectedPath)
            }
        }
        .background(WorkspaceDetailStyle.background(for: colorScheme))
        .navigationTitle("Commit Changes")
        .toolbarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var commitHeader: some View {
        VStack(alignment: .leading, spacing: CreateWorkspaceRepoStyle.rowTextSpacing) {
            Text(commit.message).interFont(Constants.Typography.bodyM).textSelection(.enabled)
            Text("\(commit.author) · \(commit.hash.prefix(WorkspaceChangesLayout.shortHashLength))")
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(WorkspaceDetailStyle.secondary(for: colorScheme, contrast: contrast))
        }
        .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
        .padding(.horizontal, CreateWorkspaceFormStyle.pagePadding)
        .padding(.top, CreateWorkspaceFormStyle.pagePadding)
    }

    private var filePicker: some View {
        VStack(alignment: .leading, spacing: CreateWorkspaceFormStyle.rowSpacing) {
            Text("File (\(files.count))")
                .interFont(Constants.Typography.bodyS)
            Menu {
                Picker("File", selection: $selectedPath) {
                    ForEach(files) { file in
                        Text("\(file.path) (+\(file.additions) −\(file.deletions))").tag(file.path)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                CreateWorkspaceChoiceLabel(title: selectedPath, surface: WorkspaceDetailStyle.surface(for: colorScheme))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("File")
            .accessibilityValue(selectedPath)
        }
        .foregroundStyle(WorkspaceDetailStyle.foreground(for: colorScheme))
        .padding(.horizontal, CreateWorkspaceFormStyle.pagePadding)
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

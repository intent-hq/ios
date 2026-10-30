import SwiftUI

struct WorkspaceCommitDetailsView: View {
    let commit: WorkspaceCommit
    @State private var copied = false
    @Environment(\.workspaceViewerUsesPanel) private var usesPanel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceCommitLayout.sectionSpacing) {
                detail("Message") { Text(commit.message).textSelection(.enabled) }
                detail("Commit") {
                    hashRow
                }
                detail("Author") { Text(commit.author).textSelection(.enabled) }
                detail("Date") {
                    if let date = ISO8601DateFormatter().date(from: commit.date) {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text(commit.date).textSelection(.enabled)
                    }
                }
                if commit.isPushedKnown {
                    detail("Status") { Text(commit.isPushed ? "Pushed" : "Not pushed") }
                }
            }
            .interFont(Constants.Typography.bodyS)
            .padding(WorkspaceCommitLayout.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(usesPanel ? IPadShellStyle.panel(for: colorScheme) : Theme.background(for: colorScheme))
        .accessibilityIdentifier("commit.details")
        .task(id: copied) {
            guard copied else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                copied = false
            } catch {}
        }
    }

    private var hashRow: some View {
        HStack(alignment: .top, spacing: WorkspaceCommitLayout.spacing) {
            Text(commit.hash)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            IntentIconButton(
                icon: copied ? .check : .copy,
                label: copied ? "Copied" : "Copy commit hash",
                showsBackground: false
            ) {
                UIPasteboard.general.string = commit.hash
                copied = true
                HapticManager.impact(.light)
            }
            .accessibilityIdentifier("commit.copy")
        }
    }

    private func detail<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: WorkspaceCommitLayout.spacing) {
            Text(title)
                .interFont(Constants.Typography.bodyXS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            content()
        }
    }
}

struct WorkspaceCommitFileLabel: View {
    let file: WorkspaceCommitFile
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WorkspaceCommitLayout.spacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: WorkspaceCommitLayout.spacing))
        return layout {
            VStack(alignment: .leading, spacing: WorkspaceCommitLayout.textSpacing) {
                Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                    .interFont(Constants.Typography.bodySEmphasized)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .truncationMode(.middle)
                let directory = file.path.split(separator: "/").dropLast().joined(separator: "/")
                if !directory.isEmpty {
                    Text(directory)
                        .interFont(Constants.Typography.bodyXS)
                        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            WorkspaceChangeStats(additions: file.additions, deletions: file.deletions)
        }
    }
}

struct WorkspaceCommitFilePicker: View {
    let files: [WorkspaceCommitFile]
    let select: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var matches: [WorkspaceCommitFile] {
        files.filter { query.isEmpty || $0.path.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(matches) { file in
                        Button { select(file.path) } label: {
                            WorkspaceCommitFileLabel(file: file)
                                .padding(WorkspaceCommitLayout.padding).contentShape(Rectangle())
                        }
                        .buttonStyle(IntentContentButtonStyle())
                        .accessibilityIdentifier("commit.jump.file.\(file.path)")
                    }
                }
            }
            .overlay {
                if matches.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, prompt: "Find a file")
            .foregroundStyle(Theme.foreground(for: colorScheme))
            .background(Theme.background(for: colorScheme))
            .navigationTitle("Jump to file")
            .toolbarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar(for: colorScheme), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    IntentIconButton(icon: .close, label: "Close file list", showsBackground: false) { dismiss() }
                }
                .intentToolbarSurface()
            }
        }
    }
}

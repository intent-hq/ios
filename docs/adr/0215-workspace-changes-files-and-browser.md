# ADR-0215: Workspace changes trust git for membership, and the workspace browser keeps the registry's address

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceChange`, `WorkspaceCommit`, `WorkspaceGitRoot`,
  `WorkspaceChangesSnapshot` (`Intent/Models/WorkspaceChanges.swift`),
  `ChangeTreeFile` (`Intent/Models/WorkspaceChangeTree.swift`),
  `WorkspaceFileEntry` (`Intent/Models/WorkspaceFileEntry.swift`),
  `WorkspaceBrowserURL` (`Intent/Models/WorkspaceBrowser.swift`)

## Context

The Changes tab shows git status rows, commits, and git roots for a workspace,
enriched with agent attribution. The Files tab lists directory entries. The
workspace browser opens daemon-proxied web pages.

## Decisions

### 1. Git owns change membership and stage

Applies to: `WorkspaceChange`,
`WorkspaceChangesSnapshot.init(_:rootId:trackedChanges:)`

File-tracking rows keep their stage, so a partly staged file appears in both
sections. Git owns membership and stage. Attribution only enriches a row with
an exact path and stage match.

### 2. Commit rows are metadata only

Applies to: `WorkspaceCommit`

Commit rows hold metadata only. Per-file diffs are fetched when the commit is
opened.

### 3. Submodule roots

Applies to: `WorkspaceGitRoot.isSubmodule`

`isSubmodule` is true for a root that the daemon detected from the worktree's
git submodules (`source: "auto"`), as opposed to a root registered by an agent.

### 4. File tree and file list entries

Applies to: `ChangeTreeFile`, `WorkspaceFileEntry`

A `ChangeTreeFile` is placed in a `ChangeTree` by its slash-separated path. A
`WorkspaceFileEntry` is a direct child returned by `file.list`, with a
workspace-relative path for previews.

### 5. Browser URL rules

Applies to: `WorkspaceBrowserURL.normalize(_:)`,
`WorkspaceBrowserURL.tabURL(current:requested:)`

An empty explicit port (`host:`) is not a usable host:port entry and is
rejected.

When the loaded page and the requested page have different origins, the
browser keeps the requested address for `127.0.0.1` and `client.localhost`.
The registry keeps the pre-rewrite address and rebases its path as the desktop
navigates, and its loaded address can use a desktop-only port.

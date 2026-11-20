# 0058. Workspace resource models: notes, tasks, scripts, changes and files

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

A workspace has notes, tasks, scripts with monitors and browsers, terminals, git changes and files. The app decodes each from daemon reads and events. Several reads are bounded or slim, and several fields are open strings. This record holds the model rules that the code alone does not show.

## Decision

1. **Notes (PROTOCOL §5.2, §5.4).**
   1. The `metadata.task` fields are omitted on the wire when empty. They decode as an empty array or nil, also on non-task notes. `unmetDependsOn` is computed by the daemon.
   2. A slim `note.list` row (`projection: "slim"`) has no `content`; it has the first 500 characters (`contentPreview`) and the total length. The list preview falls back to `contentPreview`.
   3. `contentTruncated` means the daemon cut a row too large for one read ("Bounded note and comment reads"); `contentBytes` is the full UTF-8 size.
   4. A slim row with a non-empty length and no local content is stale (`isContentStale`). Full rows and empty notes are never stale. `needsFullContent` covers slim and cut rows.
   5. `withBody(of:)` grafts a fetched body onto a cached list row; the cached row's metadata wins.
   6. Content checkboxes use only `[ ]`, `[x]` and `[/]`. `blocked` and `discussion_needed` exist only in task-note metadata status.
2. **Task statuses (PROTOCOL §5.4).** The vocabulary is `not_started`, `waiting`, `discussion_needed`, `blocked`, `in_progress`, `review_required`, `complete`, `cancelled`. Statuses stay open strings; unknown values show as `.unknown`. `blocked` and `discussion_needed` come from attention requests (`ws.agent.reportBlocker`, `requestDiscussion`) and get their own treatment: the task waits on the user (`needsAttention`).
3. **Scripts and monitors.**
   1. Runtime snapshots omit cleared fields. A missing field clears the old run's value (for example `detectedUrl`).
   2. A monitor's `createdAt` keeps the server text. An invalid date shows as unavailable, never as a guessed deadline.
   3. Only an explicitly selected active watch loads its full trigger configuration (`ScriptMonitorDetail`).
   4. The preview keeps the wire's UTF-8 bound without splitting a scalar or running the regex.
4. **Browser tabs.** An empty explicit port is not a usable `host:port`. When the current tab and the request have different origins, a request to `127.0.0.1` or `client.localhost` wins: the registry keeps the address from before the rewrite and rebases its path as the desktop navigates, and its loaded address can use a port only the desktop can reach (`tabURL(current:requested:)`).
5. **Git changes.**
   1. Git owns membership and stage. Attribution only enriches a change with the exact same path and stage.
   2. File rows keep their stage, so a partly staged file is in both sections.
   3. Commit rows are metadata only. Per-file diffs load when the commit opens.
   4. `isSubmodule` marks git roots that the daemon found from the worktree's submodules (`source: "auto"`), not roots an agent registered.
6. **Terminals.** `MobileTerminalProcess` comes from the daemon's `foregroundProcess` and `lastProcess`. It is nil when the terminal has only run its shell.
7. **Pending files.** Security-scoped access belongs to `ConversationAttachmentPipeline`, not to `PendingFile`. Every copy keeps the imported video, also during an in-flight or recoverable send.

## Consequences

- A missing field in a runtime snapshot is a clear, not "unchanged".
- Unknown task statuses still render, with a neutral treatment.

## Code

- `Note`: `contentPreview`, `contentTruncated`, `isContentStale`, `needsFullContent`, `withBody(of:)`, `taskDisplayStatus`, `preview`
- `WorkspaceTask`, `TaskDisplayStatus`: `needsAttention`
- `WorkspaceScript`, `ScriptMonitorSummary`, `ScriptMonitorDetail`
- `WorkspaceBrowser`: `normalize(_:)`, `tabURL(current:requested:)`
- `WorkspaceChange`, `WorkspaceCommit`, `WorkspaceGitRoot`: `isSubmodule`; `WorkspaceChangesSnapshot`
- `MobileTerminalProcess`
- `PendingFile`: `video`

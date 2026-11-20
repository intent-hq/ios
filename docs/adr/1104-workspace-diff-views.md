# ADR-1104: Workspace commit and file diff views measure and lay out rows

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceCommitDiffView` (`Intent/Views/Workspaces/WorkspaceCommitDiffView.swift`), `WorkspaceFileDiffView` (`Intent/Views/Workspaces/WorkspaceFileDiffView.swift`)

## Context

The commit view stacks one diff per file inside an outer scroll view. The file
diff view shows one file, either embedded in that commit view or as a full
page.

## Decisions

### 1. The commit view retains loaded diff heights

Applies to: `WorkspaceCommitDiffView.diffHeights`

Lazy layout can probe a collapsed height offscreen. The view retains loaded
heights until text sizing changes.

### 2. File diff inputs

Applies to: `WorkspaceFileDiffView.loader`, `WorkspaceFileDiffView.showsPath`

`loader` is nil when `patch` supplies the diff, which is a pull request file's
GitHub patch. `showsPath` is off when the page's own header already names the
file.

### 3. Long embedded diffs open the full page instead of expanding

Applies to: `WorkspaceFileDiffView`

Above `WorkspaceDiffRows.embeddedLineLimit`, the "Show All" button opens the
full-page diff. Expanding inline would rebuild every row; the full-page diff
builds rows lazily.

### 4. Embedded rows are not lazy

Applies to: `WorkspaceFileDiffView.diffScrollView`

The commit view's outer scroll view drives vertical scrolling, so rows cannot
be lazy in the embedded diff. The embedded diff has a fixed height
(`diffContentHeight`) to keep lazy section measurements stable when the
horizontal scroller moves offscreen.

### 5. The full-page diff has a fixed width

Applies to: `WorkspaceFileDiffView.diffScrollView`

A fixed width from the widest line keeps horizontal scrolling stable as rows
load.

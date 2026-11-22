# ADR-0153: Workspace file tree guides and media preview failures

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `WorkspaceFileTreeLabel`, `FileTreeGuides`, `FileTreeGuideShape` (`Intent/Views/Workspaces/WorkspaceFileTreeLabel.swift`), `WorkspaceFilePreview.Failure` (`Intent/Views/Workspaces/WorkspaceFilePreview.swift`)

## Decisions

### 1. Guides join into one line per open folder

Applies to: `View.fileTreeGuides(depth:)`, `WorkspaceFileTreeLabel.showsChildGuide`, `FileTreeGuideShape.ownGuide`

Each row draws a vertical guide under each ancestor folder's icon. Rows stack
without spacing, so the guides join into one line per open folder. The
folder's own label starts the line just below its icon (`showsChildGuide`).
`ownGuide` is an x offset and a distance below the vertical center where a
folder's line starts. A guide leads to an open folder's children only when
they sit deeper than it (`depth < maximumIndentationDepth`).
`guideIconGap` (3) is measured from the icon frame; the folder glyph sits
about 2 pt inside it.

### 2. Deep rows keep part of the path

Applies to: `WorkspaceFileTreeLabel.displayName(path:depth:)`

Rows past the deepest indentation keep the path below their last indented
ancestor.

### 3. Closing a folder is faster than opening it

Applies to: `WorkspaceFileTreeLabel.folderCloseDuration`

Closing (0.18 s) runs a little faster than opening (0.25 s) so collapsing
feels immediate.

### 4. Media preview failures name the real cause

Applies to: `WorkspaceFilePreview.Failure`

The failure enum exists so the message names the real cause instead of always
blaming the connection.

1. `tooLarge`: over the loader's size cap in bytes; retrying cannot help.
2. `unsupported`: a type this device cannot show at all (WebM video).
3. `damaged`: a supported type whose bytes did not decode. Refetching returns
   the same bytes, so retrying cannot help. Every extension routed to the
   media preview is one this device decodes, so `notAnImage` or `notAVideo`
   means bad bytes.
4. `unexpectedResponse`: the daemon answered with a reply the loader could not
   read (`malformedResponse`), which is neither a size, type nor byte problem.
5. `unavailable`: the request itself failed (timeout, disconnect, server error).

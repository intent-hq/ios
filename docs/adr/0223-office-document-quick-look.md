# ADR-0223: Office and iWork files open in Quick Look

- Status: Accepted
- Recorded: 2026-11-25
- Applies to: `WorkspaceDocument` (`Intent/Services/WorkspaceDocument.swift`), `WorkspaceFileImageLoader.document(workspaceId:path:)` (`Intent/Services/WorkspaceFileImageLoader+Documents.swift`), `DocumentLightboxView` and `DocumentQuickLookView` (`Intent/Views/Conversation/Content/DocumentLightboxView.swift`), `WorkspaceFilePreview` (`Intent/Views/Workspaces/WorkspaceFilePreview.swift`), `ContentBlockBody.textURLRoute(for:workspaceId:)` (`Intent/Views/Conversation/Content/ContentBlockView.swift`)

## Context

Agents link spreadsheets and other Office files in chat, and the Files tab lists
them. These files are binary. Before this record they went to the text viewer,
which rejects binary files and showed "Text file unavailable".

## Decisions

### 1. Quick Look renders the file

Applies to: `DocumentQuickLookView`

`QLPreviewController` renders Office and iWork files on iOS and visionOS with no
third-party code and no bundled renderer. The controller is embedded as the
content of the app's own navigation stack, so the title, Close and Share match
the PDF viewer.

### 2. The extension list is explicit

Applies to: `WorkspaceDocument.pathExtensions`

Only `xlsx`, `xls`, `docx`, `doc`, `pptx`, `ppt`, `numbers`, `pages` and `key`
take this route. CSV stays in the text viewer, which already opens it and
offers line numbers and Copy contents. Every other extension keeps its earlier
route.

### 3. The temporary file keeps the original file name

Applies to: `WorkspaceDocument.load(path:download:)`

Quick Look selects its renderer from the path extension, and the share sheet
shows the file name. The download therefore goes to a per-file directory under
the temporary directory and keeps the last path component as its name. The
directory is removed when the last owner releases the `WorkspaceDocument`.

### 4. Document links share the media cover

Applies to: `ContentBlockBody.openTextURL(_:)`, `WorkspaceFilePreview`

`.document` is a separate route so the routing stays testable, but it presents
the same `WorkspaceFilePreview` cover as `.media`. That view already owns the
loading state, the failure messages, Retry and retry on reconnect. A separate
cover would add one more presentation modifier to every transcript text block.

## Consequences

Quick Look draws a spreadsheet at its own scale. A small sheet looks small on an
iPhone until the user zooms. The app does not control this.

## Verification

`DocumentLinkUITests` opens the demo spreadsheet from a chat link in light and
dark appearance, checks that a cell renders, checks the share sheet name, and
checks the failure state for a missing file. `WorkspaceDocumentLoaderTests`
covers the chunked download, the cache, the size limit and Retry.
`ContentBlockLinkTests` covers the route.

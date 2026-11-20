# ADR-0807: Markdown text routes media through the daemon and the window's session

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `MarkdownTextView` (`Intent/Views/Conversation/Content/MarkdownTextView.swift`), `MarkdownImageRoute`, `IntentFileAttachmentLoader`, `IntentFileImageAttachment`, `IntentFileFailureAttachment` (`Intent/Views/Conversation/Content/IntentFileAttachmentLoader.swift`), `IntentFileVideoFailureAttachment` (`Intent/Views/Conversation/Content/IntentFileVideoAttachment.swift`), `IntentFilePDFAttachment` (`Intent/Views/Conversation/Content/IntentFilePDFAttachment.swift`)

## Context

Transcript and note text renders through Textual's `StructuredText`. Markdown
images can point at workspace files (`intent://local/[ws-id/]file/<path>`),
saved assets (`workspace-asset://`), or remote http(s) URLs. Textual renders
attachments as sized symbols in the text run, and its own tap handler owns
attachment taps.

## Decisions

### 1. Image URLs are routed by scheme, and cleartext http is claimed on purpose

Applies to: `MarkdownImageRoute`, `MarkdownImageRoute.route(for:)`

Intent-file and saved-asset images go through the daemon. Remote http(s) URLs
go through `RemoteImageLoader`. Everything else goes through the wrapped
fallback loader.

Cleartext `http` is claimed deliberately. ATS (`NSAllowsLocalNetworking` only)
permits local-network http, for example images served by the daemon at
127.0.0.1, which therefore load and get the lightbox. Non-local http fails ATS
inside `RemoteImageLoader` and falls through to the fallback loader. That
loader shares URLSession's ATS policy and fails the same way, so routing it
here loses nothing.

Malformed saved-asset URLs are claimed too, so they fail locally instead of
reaching Textual's network fallback.

### 2. The loader never throws for daemon links

Applies to: `IntentFileAttachmentLoader`, `IntentFileAttachmentLoader.remoteImageAttachment(for:text:)`, `IntentFileFailureAttachment`

`IntentFileAttachmentLoader` renders `![alt](intent://local/[ws-id/]file/<path>)`
images, videos and PDFs and `workspace-asset://` media by fetching bytes from
the daemon, and remote http(s) images with `RemoteImageLoader`. Videos open
full-screen playback. Images open the lightbox. Other URLs use the wrapped
fallback loader (Textual's default network loader).

The loader never throws for intent-file or saved-asset links. Failures degrade
to a placeholder attachment (`IntentFileFailureAttachment`, also used for
non-image extensions and a missing workspace) without breaking the surrounding
text. Saved-asset documents (PDF and text) are not supported by this route and
get the placeholder. A failed remote load returns nil from
`remoteImageAttachment` and falls through to the fallback loader, which keeps
its behavior for broken URLs.

### 3. Fetchers are injectable and bound to the window's session

Applies to: `IntentFileAttachmentLoader.workspaceId`, `remoteImage`, `fileImage`, `assetMedia`, `MarkdownTextView.session`, `MarkdownTextView.fileImageFetcher`, `MarkdownTextView.assetMediaFetcher(session:)`, `MarkdownTextView.workspaceId`

1. `workspaceId` resolves short-form links that have no workspace segment.
   Intent-file images still render when it is nil if the link carries its own
   workspace ID (long form).
2. `remoteImage` fetches and decodes a remote image. It is injectable for
   tests.
3. `fileImage` is injectable so a window routes through its session's
   `WorkspaceFileImageLoader` instead of the shared (default-backend) loader.
4. `assetMedia`: saved assets use the same session-bound loader, cache and
   decode limits.
5. `MarkdownTextView` reads the window's `BackendSession` when present, so
   workspace images load over its backend connection. Saved images bind to the
   window's session, never to URL backend hints.

### 4. A qualified cast pins the existential initializer

Applies to: `IntentFileAttachmentLoader.attachment(for:text:environment:)`

The `as any Textual.Attachment` cast pins `AnyAttachment`'s existential
initializer. Newer compilers (Xcode 26.x) treat the `some`/`any` overload pair
as ambiguous for concrete arguments. The cast is module-qualified because
inside this type `Attachment` resolves to the `AttachmentLoader` associated
type (`AnyAttachment`), not the protocol.

### 5. The resolution core is testable without Textual's environment

Applies to: `IntentFileAttachmentLoader.resolvedAttachment(for:text:fallback:)`

`resolvedAttachment` is the environment-free core of `attachment(for:)`. It is
testable without a `ColorEnvironmentValues`, whose initializer is internal to
Textual. The fallback loader call is passed in as a closure.

### 6. Attachment symbols size to Textual's run bounds

Applies to: `IntentFileImageAttachment`, `IntentFileFailureAttachment.sizeThatFits(_:in:)`, `IntentFileVideoFailureAttachment`, `IntentFilePDFAttachment`

1. A loaded markdown image (intent-file, saved asset or remote http(s)) is
   embedded in text as `IntentFileImageAttachment`. `MarkdownTextView`'s
   attachment tap handler routes its taps to open the lightbox.
2. Textual's ideal-sized symbol must match the measured image proportions.
3. Textual draws an ideal-sized symbol into the square run bounds, so the PDF
   card and the video failure card use a square frame. The video failure card
   is a Canvas symbol that Textual scales into the square, which keeps its
   labels from stretching.
4. `IntentFileFailureAttachment.sizeThatFits` matches the Inter label and the
   native SF Symbol at the current text traits. Typed trait setters support
   Textual's off-main measurement without actor-isolated property access.
5. Textual renders attachment bodies as symbols, so its tap handler owns retry.
   `IntentFileVideoFailureAttachment.prepareRetry(using:)` clears the same
   session loader used to fetch, before the markdown is resolved again.

### 7. Markdown text view behavior

Applies to: `MarkdownTextView`

1. `linkStyle == .chat` renders single-link lines as full-width rows.
2. `markdownSource` is prepared once and reused across view reconstruction and
   conversation visits.
3. Textual resolves URLs once per attributed string. An explicit retry bumps
   `attachmentAttempt`, which recreates that state with `.id`. Successful
   media still uses the cache.
4. SwiftUI draws link runs in the tint. The tint is set to the text color, so
   links match the text and are underlined instead.
5. `lightboxImage(for:)`: only loaded markdown images (intent-file, saved
   assets and remote http(s)) open the image lightbox. Videos and retry
   placeholders have separate actions in the attachment tap handler.

### 8. GFM task-list markers are replaced before parsing

Applies to: `MarkdownTextView.replacingTaskListMarkers(_:)`, `taskListMarker`, `listItemMarker`, `leadingIndentWidth(of:)`

Textual's Markdown parser (Foundation's, cmark-based) has no task-list
extension, so `- [ ]` and `- [x]` markers would render as literal brackets.
`replacingTaskListMarkers` swaps them for checkbox glyphs and skips fenced and
indented code blocks.

1. `taskListMarker` matches a GFM task-list line: optional blockquote prefix,
   indent, list marker (bullet or ordered), then a `[ ]` or `[x]` marker.
2. `listItemMarker` matches any list-item line, task or not. It tracks list
   continuation, so nested items indented 4 or more columns are not mistaken
   for indented code.
3. `leadingIndentWidth` counts leading indentation in columns. A tab advances
   to the next multiple of 4, matching CommonMark's tab-stop rule.

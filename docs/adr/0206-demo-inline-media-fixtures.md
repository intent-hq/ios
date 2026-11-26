# ADR-0206: Inline media fixtures are opt-in and self-contained

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `DemoFixtures` inline-media members (`Intent/Demo/DemoFixturesInlineImages.swift`, `Intent/Demo/DemoFixturesInlinePDF.swift`, `Intent/Demo/DemoFixturesInlineText.swift`, `Intent/Demo/DemoFixturesInlineDocument.swift`, `Intent/Demo/DemoFixturesTranscriptVideo.swift`)

## Context

UI tests need transcripts that link images, PDFs, text files, HTML reports,
spreadsheets, and video. These fixtures must not change the default demo or need a network.

## Decisions

### 1. Each inline-media scenario is opt-in

Applies to: `DemoFixtures.inlineImageConversationRequested(by:)`,
`DemoFixtures.usesInlinePDF`, `DemoFixtures.usesInlineText`,
`DemoFixtures.usesInlineDocument`

Each scenario needs its own launch argument, so existing demo screenshots and
transcript fixtures stay unchanged.

### 2. Inline images use one assistant text block and the existing asset fixture

Applies to: `DemoFixtures.inlineImageConversationMessages`

The scenario serves one real assistant text block through both
`chat.subscribe` and `agent.getConversation`. The existing `note.readAsset`
fixture supplies the PNG. The unknown asset returns an empty payload. Neither
needs a network. The linked workspace intentionally differs from the
conversation's workspace.

### 3. Image captions use explicit hard breaks

Applies to: `DemoFixtures.inlineImageResponseText`

Explicit hard breaks keep each caption and its attachment in one paragraph.
That paragraph's real layout bounds are observable by XCUITest, even though
Textual draws the attachment body as a Canvas symbol.

### 4. A duplicated suggested-prompts opener is a controlled case

Applies to: `DemoFixtures.inlineImageResponseText`

The text reproduces a raw opener beside otherwise valid prompt buttons. The
original report has no raw payload, so this is a controlled case.

### 5. Generated files need no network, external tool, or bundle resource

Applies to: `DemoFixtures.inlinePDFBytes`, `DemoFixtures.inlineReportChartBytes`

The PDF and the report chart are generated once in memory.

### 6. The HTML report exercises relative, absolute, and unopenable links

Applies to: `DemoFixtures.inlineHTMLPath`, `DemoFixtures.inlineReportStylesheetPath`,
`DemoFixtures.inlineWorkspaceFolder`, `DemoFixtures.inlineTextMessages`

The report is linked as a relative path, the way agents often write report
links. Its stylesheet and assets are referenced by relative URLs, as generated
reports do. `inlineWorkspaceFolder` is where the demo workspace sits on the Mac,
for links written as absolute paths. The daemon accepts an absolute path inside
the workspace, so the report's files are served from both paths. The transcript
also has links the app cannot open; each tap shows a message instead of doing
nothing.

### 7. The report font is the app's bundled Inter under a report-only family name

Applies to: `DemoFixtures.inlineReportFontBytes`

The font is the app's own bundled Inter (SIL OFL 1.1, `Inter-LICENSE.txt`). The
web content process cannot see app-registered fonts, so the report renders it
only through `@font-face`.

### 8. The report proves that its external stylesheet loaded

Applies to: `DemoFixtures.inlineHTMLBytes`

The inline rule hides the note. Only the external stylesheet shows it, so the
note's presence proves that the relative stylesheet loaded.

### 9. The transcript video is inline H.264 bytes

Applies to: `DemoFixtures.transcriptVideoBytes`

The video is a two-second H.264 MP4, 160×90: a yellow square on a steel-blue
background. It was generated once with ffmpeg `color` + `drawbox`, `libx264`,
`yuv420p`, `+faststart`. Inline bytes keep the opt-in demo independent of the
network and of bundle lookup.

### 10. The spreadsheet is inline XLSX bytes

Applies to: `DemoFixtures.inlineSpreadsheetBytes`

The spreadsheet is a one-sheet XLSX with a header row and four quarters. It was
generated once with Python `zipfile` from five hand-written XML parts. Foundation
cannot write a ZIP archive, so the file cannot be generated in memory the way the
PDF is. Inline bytes keep the opt-in demo independent of the network and of
bundle lookup.

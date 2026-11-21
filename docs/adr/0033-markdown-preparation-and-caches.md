# ADR-0033: Markdown preparation, bounded caches and link rows

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `BoundedMarkdownCache` (`Intent/Presentation/BoundedMarkdownCache.swift`), `MarkdownContentCache` (`Intent/Presentation/MarkdownContentCache.swift`), `MermaidMarkdownContent` (`Intent/Presentation/MermaidMarkdownContent.swift`), `StandaloneLinkRow` (`Intent/Presentation/StandaloneLinkRow.swift`)
- Related issues: ios#1015

## Context

Markdown in the transcript is prepared (Mermaid extraction, task-list markers)
and parsed many times. `MarkdownContentCache` shares this work across views
through two `BoundedMarkdownCache` instances.

## Decisions

### 1. The cache is a synchronous LRU with hard entry and cost limits

Applies to: `BoundedMarkdownCache.value(for:version:cost:create:)`

The cache has a hard entry limit and a hard accounted-cost limit. The cost
includes the source key bytes. A value too large to fit is returned to the
caller without being stored, so it does not displace the reusable working set.

Recency bookkeeping is linear in the entry count. That is acceptable only
while the entry limit stays small; raising it substantially needs an O(1)
recency structure.

### 2. Keys compare the exact UTF-8 bytes of the source

Applies to: `BoundedMarkdownCache.CacheKey`

`String` equality folds canonically equivalent Unicode. Markdown code and URLs
must keep their exact spelling, so key equality and hashing use all UTF-8 bytes
(`Data`), not the `String`.

### 3. Failures are not cached

Applies to: `BoundedMarkdownCache.value(for:version:cost:create:)`

An error from `create` propagates to the caller. It is never stored as an empty
successful parse.

### 4. Only source preparation and semantic parsing are shared

Applies to: `MarkdownContentCache`

The cache holds source preparation and semantic parsing only. Textual still
resolves attachments and applies the current session, style and layout on each
view.

### 5. Version keys separate parser semantics and variants

Applies to: `MarkdownContentCache.preparationVersion`, `parserVersion`, `standaloneLinkRowsVariant`

Bump `preparationVersion` or `parserVersion` when preparation or parser
semantics change. The parser has one fixed configuration: Foundation defaults,
nil base URL, no syntax extensions. Future parser options must get distinct
keys before they share this store. `standaloneLinkRowsVariant` offsets the key
of the chat variant, so the link-rows parse never shares an entry with the
plain parse.

### 6. Chat uses the link-rows parse

Applies to: `MarkdownContentCache.attributedStringWithLinkRows(for:)`, `MarkdownContentCache.LinkRowsParser`

Chat's parser rewrites each single-link paragraph into a `StandaloneLinkRow`
block, so standalone link lines become full-width rows. That result is cached
separately from the plain parse.

### 7. Parse cost is a conservative charge, not a heap size

Applies to: `MarkdownContentCache.parsedCost(input:value:)`

Foundation's storage size for `AttributedString` is opaque. The cost charges
conservatively for the source, the attributed characters and the semantic runs.
It is not a claim about heap size.

### 8. Mermaid fences become placeholders inside one Markdown document

Applies to: `MermaidMarkdownContent.init(_:)`

A closed Mermaid fence is replaced in place by a placeholder fence line keyed
by its source. The content stays one Markdown document, so reference links and
lists keep their context.

A Mermaid fence that is only opened (the diagram is still streaming) becomes
`pending`. Its placeholder is a nonempty code block ("Generating diagram"),
because a nonempty code block keeps an opening-only fence visible in the
Markdown parser.

### 9. Single-link paragraphs render as full-width rows

Applies to: `StandaloneLinkRow`, `StandaloneLinkRow.init?(paragraph:)`, `StandaloneLinkRow.rewriting(_:)`

A paragraph or list item whose whole text is one link, such as an agent's
"Open the report" line, renders in chat as a full-width row instead of an
inline run. Textual hit-tests inline links on their glyphs only (ios#1015),
so a line that is only a link is hard to tap.

Textual's block styles receive a type-erased label, not the paragraph's
content. The parse step therefore rewrites the paragraph into a code block
whose language hint carries the row. The code block style of
`CompactMarkdownStyle` recognizes the hint and draws `StandaloneLinkRowView`.
Parsed Markdown cannot produce the hint, because info strings never contain
the unit separator (`\u{1F}`). The rewrite keeps the list, quote and identity
context of the paragraph.

A paragraph forms no row when any visible text is not part of one link, or
when the paragraph shows an image.

### 10. Only workspace files get a file icon

Applies to: `StandaloneLinkRow.opensFile`

Workspace files (intent file links and relative paths) get a file icon. Every
other destination gets a chevron.

## Consequences

Markdown parse cost is bounded per process, and a parser change invalidates
old entries through the version keys.

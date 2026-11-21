# 0064. Markdown parse caches and link rows

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Chat and notes parse the same Markdown many times while rows re-render. Textual renders the parsed result. Textual hit-tests inline links on their glyphs only (ios#1015), so a line that is only a link is hard to tap.

## Decision

1. **Bounded cache.** `BoundedMarkdownCache` is a synchronous LRU with hard entry and cost limits; source keys count toward the cost.
   1. A value larger than the limit is returned without displacing the working set.
   2. Keys compare and hash all UTF-8 bytes. `String` equality folds canonically equivalent Unicode, but code and URLs must keep their exact spelling.
   3. A failed parse propagates and is never cached as an empty success.
   4. Recency bookkeeping is linear. That is acceptable only while the entry limit stays small.
2. **Semantic store.** `MarkdownContentCache` shares source preparation and the semantic parse only. Textual still resolves attachments and applies session, style and layout per view.
   1. The parser has one fixed configuration: Foundation defaults, nil base URL, no syntax extensions. Bump `preparationVersion` when preparation or parse semantics change. A new option needs its own key before it shares the store.
   2. The link-row variant uses an offset key, so it never shares an entry with a plain parse.
   3. Cost is a conservative charge for source, characters and runs. It is not a heap-size claim.
3. **Standalone link rows.**
   1. A paragraph or list item whose whole visible text is one link, with no image, renders as a full-width row in chat.
   2. Textual block styles get a type-erased label, so the parse step rewrites the paragraph into a code block whose language hint carries the row. `CompactMarkdownStyle` recognizes the hint. Parsed Markdown cannot produce the hint, because info strings never contain the unit separator. List, quote and identity context are kept.
   3. Workspace files (intent file links and relative paths) get a file icon; other destinations get a chevron.
4. **Mermaid in Markdown.** A diagram fence is replaced in place, so the document stays one Markdown document and reference links and lists keep their context. The placeholder is a non-empty code block, so an opening-only fence stays visible.
5. **Tool results.** `pairToolResults` matches `tool_result` blocks to their `tool_use` by `resolvedToolUseId` / `toolCallId`, first match wins, once per message. Each row gets only its own result.

## Consequences

- Markdown parse cost is bounded per process, and a parser change invalidates old entries by key.

## Code

- `BoundedMarkdownCache`: `value`, `touch`
- `MarkdownContentCache`: `preparedContent(for:)`, `attributedString(for:)`, `attributedStringWithLinkRows(for:)`, `LinkRowsParser`
- `StandaloneLinkRow`: `init?(paragraph:)`, `opensFile`, `rewriting(_:)`
- `MermaidMarkdownContent`
- `MessageBlockPartitioning`: `pairToolResults(_:)`

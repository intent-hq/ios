# ADR-0303: Suggested prompt blocks follow the desktop parser

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `SuggestedPrompts` (`Intent/Presentation/SuggestedPrompts.swift`), `SuggestedPromptLinks` (`Intent/Presentation/SuggestedPromptLinks.swift`)
- Related issues: ios#445, intent-hq/intent#3936

## Context

Agents end a reply with a `<!-- suggested-prompts ... -->` block. The app shows
its lines as prompt chips and strips the block from the rendered text. The
desktop app parses the same blocks, and both clients must agree. Shared cases
are in `IntentTests/Fixtures/suggested-prompts/` and in the monorepo file
`docs/protocol/suggested-prompts.md`.

## Decisions

### 1. The base syntax mirrors the desktop parser

Applies to: `SuggestedPrompts`

The base syntax mirrors `scanSuggestedPrompts` and `parseSuggestedPrompts` in
the desktop app's `messageParser.ts`. This includes `Label|` and `delay:N|`
stripping, the four-chip cap, and dropping individually invalid lines.

### 2. What a well-formed block is

Applies to: `SuggestedPrompts.blocks(in:)`, `SuggestedPrompts.findCloser(in:after:closer:)`

A block is well-formed only when:

1. the opener ends its own line,
2. a later line closes it: either a standalone `-->`, or a line that ends in
   `-->` whose non-empty remainder becomes the final body line, and
3. the opener is not inside a fenced code region.

An embedded `-->` in the middle of a line (a Mermaid edge, a prose arrow) never
closes a block. A second opener means that the first one was never closed.
A closer or opener inside a fenced region never counts, so a fenced example
cannot close the block and strip reply text. A remainder shaped like an opener
must not close the block: stripping is ungated and would delete text under an
unclosed opener.

When an opener is not closed, the scan continues from the next line. The fence
bookkeeping then sees every line, and a later well-formed block is still found.

`blocks(in:)` returns every well-formed block, in order, ungated.

### 3. Every block is stripped; only the last block supplies prompts

Applies to: `SuggestedPrompts.parse(_:)`, `SuggestedPrompts.prompts(fromLastOf:)`, `SuggestedPrompts.looksLikeBodyText(_:)`

Every well-formed block is stripped from the rendered text. Only the last block
supplies prompts. It yields nothing when any captured line is shaped like body
text (a heading, a fence, a table row, a Mermaid edge), so response body text
can never render as chips. Mermaid edges cannot be prompts.

### 4. Repeated empty openers before a closed block belong to that block

Applies to: `SuggestedPrompts.redundantOpenerStart(in:before:prefix:)`

Empty repeated opener lines directly before a closed block are part of that
block. Only standalone openers separated by whitespace are absorbed, and only
after a closed block has been found. The scan stops at any prose or fence, so
an earlier unclosed example cannot consume response text (ios#445). Unclosed
openers with body text after them survive. This recovery also removes a
leftover marker that iOS would otherwise show.

### 5. The HTML-escaped spelling is a block too

Applies to: `SuggestedPrompts.Block.escaped`, `SuggestedPrompts.decodeEntities(_:)`, `SuggestedPrompts.numericReference(_:)`

A model can copy `&lt;!-- suggested-prompts` ... `--&gt;` from an XML-escaped
history replay. Such a block closes only on the escaped closer `--&gt;`, and
its lines are entity-decoded once.

`decodeEntities` decodes the entities that a model imitating escaped text
emits, in one pass (so `&amp;lt;` becomes `&lt;`): the five XML named entities,
decimal references with 1 to 7 digits, and hex references with 1 to 6 digits.
Unknown, zero, out-of-range and surrogate references stay literal. This matches
the desktop's `decodeEscapedPromptText`. The search for `;` looks only as far
as the longest entity body, so a run of `&` without a nearby `;` stays linear.

### 6. The message-level scan joins all text blocks and maps ranges back

Applies to: `SuggestedPrompts.parse(contentBlocks:)`, `SuggestedPrompts.utf16Ranges(of:in:)`

The message-level scan mirrors the desktop's
`parseSuggestedPromptsFromContentBlocks` (`messageParser.ts`). The text of every
`.text` block is joined with the empty separator, as on the desktop, and
scanned once. Each block's range is mapped back into its source blocks, so
markup that is well-formed only across text-block boundaries is still
stripped. Prompts and stripping come from this single scan, so they cannot
disagree (intent-hq/intent#3936: chips rendered while the raw markup leaked).
Non-text blocks pass through untouched.

A range runs from the opener (any prefix before it survives) through the
trailing newline of the closer line, clamped at the end of the text. Consuming
that newline keeps the result identical to the line-based `stripBlocks(from:)`,
which drops whole lines with their separator. The message-level pass therefore
never turns a Markdown line break into a paragraph break. Offsets are UTF-16
units, not `Character`s, so they stay additive across block boundaries:
grapheme clusters can merge when block texts are joined.

### 7. Prompt lines follow the desktop's line rules

Applies to: `SuggestedPrompts.maxPrompts`, `parsePromptLine(_:)`, `afterDelayPrefix(_:)`, `isValidPrompt(_:)`, `promptTrimSet`, `lineTerminators`

- `maxPrompts` is 4. It matches the desktop cap and the harness instruction
  "write 2–4 prompts".
- `parsePromptLine` strips `Label|` and `delay:N|` prefixes like the desktop's
  `parseSuggestedPromptLine`. Empty or over-long results are dropped.
- The delay pattern uses `[0-9]`, not `\d`, so digit matching stays ASCII-only
  like the desktop's non-Unicode JS regex. ICU `\d` would also match, for
  example, Arabic-Indic digits.
- Like the desktop's `/^delay:(\d+)\|(.*)$/i`, the text after `delay:N|` must
  not span a line terminator. A decoded `&#10;` can put one inside a prompt.
  `lineTerminators` holds the characters that the desktop's `.` never matches.
- A prompt is valid when it is non-empty and its visible text (link labels in
  place of their markdown) fits `maxPromptLength`, like the desktop.
- `promptTrimSet` is what JS `String.prototype.trim` removes: whitespace and
  line terminators, plus the U+FEFF byte-order mark that Foundation keeps.

### 8. Fence rules

Applies to: `SuggestedPrompts.nextFence(after:in:)`

Only a matching, at-least-as-long, bare marker closes an open fence. Any marker
opens a fence otherwise.

### 9. Inline links in prompts are ported from the desktop

Applies to: `SuggestedPromptLinks`

`SuggestedPromptLinks` is ported from the desktop's
`suggested-prompt-markdown-links.ts`, so both clients measure and split prompts
the same way. Only well-formed inline links with a non-empty label and an
`http://`, `https://` or `intent://` destination count. Images, other schemes,
reference-style links and unbalanced brackets stay literal text.

- `Construct.end` is the index just past the construct, or past the literal
  span that it collapses to.
- `textAfterLabel(_:)` returns the text after the legacy `Label|` delimiter:
  the first `|` outside any inline link.
- `bracketConstruct(_:open:)` tracks nested brackets so a rejected outer
  construct is consumed whole. A bracket that never closes swallows the rest
  of its line.
- `destination(_:start:)` accepts no whitespace or angle brackets, and one
  level of balanced parentheses.

### 10. Chip labels show links but do not make them tappable

Applies to: `SuggestedPromptLinks.displayText(_:)`

A chip's label renders inline markdown, with links underlined in the chip's
own text color. The chip sends the prompt on tap, so its links are not
separately tappable and carry no link attribute.

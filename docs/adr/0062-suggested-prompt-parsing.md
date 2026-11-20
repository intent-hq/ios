# 0062. Suggested prompt parsing

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

Agents end a reply with a `<!-- suggested-prompts ... -->` block. The client strips the block from the rendered text and shows its lines as chips. The desktop app parses the same blocks. Both clients share cases in `IntentTests/Fixtures/suggested-prompts/` (monorepo `docs/protocol/suggested-prompts.md`).

## Decision

1. **Desktop parity.** Parsing mirrors the desktop `messageParser.ts` (`scanSuggestedPrompts`, `parseSuggestedPrompts`, `parseSuggestedPromptLine`, `parseSuggestedPromptsFromContentBlocks`, `decodeEscapedPromptText`) and `suggested-prompt-markdown-links.ts`. A behavior change needs a shared fixture and a desktop change.
2. **Well-formed block.**
   1. The opener ends its own line and is not inside a fenced code region.
   2. A later line closes it: a standalone `-->`, or a line that ends in `-->` whose non-empty remainder becomes the last body line. An embedded `-->` mid-line (a Mermaid edge, a prose arrow) never closes a block. An opener-shaped remainder never closes a block, because stripping is ungated.
   3. A second opener means the first was never closed. Scanning restarts on the next line, so fence tracking sees every line and a later block is still found.
   4. A fence closes only on a matching, at-least-as-long, bare marker. Openers and closers inside a fence never count, so a fenced example cannot strip reply text.
   5. Empty duplicate opener lines just before a closed block belong to that block. Only whitespace-separated standalone openers are absorbed, and only after a closed block is found; prose or a fence stops the absorption (ios#445).
   6. The HTML-escaped spelling (`&lt;!-- suggested-prompts` … `--&gt;`) is also a block. It closes only on the escaped closer, and its lines are entity-decoded once: the five XML named entities, decimal (1–7 digits) and hex (1–6 digits) references. Unknown, zero, out-of-range and surrogate references stay literal. The entity scan looks only as far as the longest entity body, so it stays linear.
3. **Stripping and prompts.**
   1. Every well-formed block is stripped. Only the last one supplies prompts.
   2. The last block yields nothing when its body is empty or any line is body-text-shaped (heading, fence, table row, Mermaid edge), so reply text never renders as chips.
   3. A message is scanned once over the joined text of all `.text` blocks (empty separator, as in the desktop). Block ranges are UTF-16 offsets mapped back to the source blocks, because grapheme clusters can merge across block boundaries. Prompts and stripping come from the same scan, so they cannot disagree (intent-hq/intent#3936).
   4. A stripped range runs through the closer line's newline, so the message-level result equals the line-based `stripBlocks(from:)` and no line break becomes a paragraph break.
4. **Prompt lines.**
   1. At most `maxPrompts` (4) chips, matching the desktop cap and the harness instruction. Invalid lines drop individually.
   2. `Label|` and `delay:N|` prefixes are stripped. Digits match `[0-9]` only, like the desktop's non-Unicode JS regex. After `delay:N|` the rest must not span a line terminator.
   3. A prompt is valid when its visible text (link labels in place of Markdown) is non-empty and fits `maxPromptLength`. Trimming matches JS `String.prototype.trim`, including U+FEFF.
5. **Links in prompts.**
   1. Only well-formed inline `[label](url)` links with a non-empty label and an `http://`, `https://` or `intent://` destination count. Images, other schemes, reference links and unbalanced brackets stay literal.
   2. Nested brackets are tracked so a rejected outer construct is consumed whole. A bracket that never closes swallows the rest of its line. A destination has no whitespace or angle brackets and at most one level of balanced parentheses.
   3. The legacy `Label|` delimiter is the first `|` outside any inline link.
   4. A chip renders its links underlined in the chip's text color, with no link attribute. The chip sends the prompt on tap, so links are not separately tappable.

## Consequences

- iOS and desktop show the same chips for the same reply.

## Code

- `SuggestedPrompts`: `parse(_:)`, `stripBlocks(from:)`, `maxPrompts`, `maxPromptLength`, `promptTrimSet`, `lineTerminators`, `redundantOpenerStart(in:before:prefix:)`
- `SuggestedPromptLinks`: `visibleText(_:)`, `textAfterLabel(_:)`, `displayText(_:)`
- `SuggestedPromptsContractTests`

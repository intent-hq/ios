# ADR-0023: Daemon-persisted transcript notices are classified by metadata and fall back to the generic banner

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AttentionNoticeKind`, `AttentionNotice` (`Intent/Models/AttentionNotice.swift`),
  `TurnFailureCategory`, `TurnFailureSummary` (`Intent/Models/TurnFailureSummary.swift`),
  `ModelChangeNotice` (`Intent/Models/ModelChangeNotice.swift`),
  `QuestionsDismissedNotice` (`Intent/Models/QuestionsDismissedNotice.swift`)

## Context

intentd persists some transcript rows that describe an event instead of a
message: attention requests, turn failures, model changes, and question
dismissals. The transcript shows them as chips or cards. Rows the client does
not recognize keep the generic system banner. The web client (cloudlands-fe)
has the same notices.

## Decisions

### 1. Attention-request notices

Applies to: `AttentionNoticeKind`, `AttentionNotice`,
`ConversationMessage.attentionNotice`, `ConversationMessage.joinedTextContent`

An attention notice is a daemon-persisted transcript notice (PROTOCOL §5.5
agent attention requests). It is raised by
`ws.agent.requestDiscussion(reason)` or `ws.agent.reportBlocker(reason)`, or
appended by intentd when a turn ends in a terminal failure (`turn-failure`).

The notice is a system-role message whose first content block carries
`meta.kind` = `"discussion-request"`, `"blocker-report"`, or `"turn-failure"`.
Every other message returns `nil`. Unknown kinds fall back to the generic
system banner. Web parity: `attention-notice.ts`.

`joinedTextContent` joins and trims all text-block content (web parity:
`extractAllContent`). It is used for notice reasons and for the generic
system-row fallback banner.

### 2. Turn failures are summarized client-side with intentd's markers

Applies to: `TurnFailureCategory`, `TurnFailureSummary`,
`TurnFailureSummary.classify(reason:hints:)`, `TurnFailureSummary.retryHint(in:)`,
`EmbeddedError`

The category of a `turn-failure` notice is inferred client-side from the reason
text. It mirrors the markers that intentd uses in
`crates/intent-acp/src/error.rs`. Structured hints win. Otherwise only the
phrasings that intentd matches count, so generic "limit reached", "quota", or
tool "timeout" text stays `.generic`.

`TurnFailureSummary(reason:)` is pure and total. Any input, including empty or
malformed text, yields a summary, and the original text is always kept verbatim
in `rawDetails` for a "Details" disclosure and Copy.

- `title` is a short headline for the category ("Usage limit reached").
- `message` is a human sentence with wrapper prefixes, RPC codes, and JSON
  stripped. It is `nil` only when the peeled reason is empty. Otherwise it falls
  back to a JSON string field, the category sentence, or the peeled text.
  `fallbackMessage` is used when a valid JSON reason carries a category signal
  but no human string field.
- `retryHint` is the provider's own reset wording ("try again at Nov 14th, 2026
  8:07 AM", "resets 3pm"), when present. It ends at a sentence-ending period,
  `·`, a newline, or the end; `a.m.` and `p.m.` do not end it. A "try again …"
  phrase counts only when it names a time or date ("in a moment" does not).
- `linkURL` is the first http(s) link in the human text, when present.

`EmbeddedError` describes what a peeled reason carries besides plain text:

- `object`: a valid JSON object starts at the first `{`. `text` is its best
  human string field, and `leading` is the text before the object. The human
  field is `message`, `details`, `detail`, `reason`, or a string `error`, each
  searched breadth-first so top-level wins; then `error.type`; then a top-level
  `type` other than the envelope value `"error"`.
- `unparsed`: a `{` that is not valid JSON (truncated JSON, or prose like
  "Invalid value {foo}"). `message` is a best-effort `"message":"…"` scan.

### 3. Model-change notices

Applies to: `ModelChangeNotice`, `ConversationMessage.modelChangeNotice`

When a turn starts under a different model or provider identity than the last
committed turn, intentd persists an informational `role: "system"` row
(PROTOCOL §5.5, `agent.setModel`) with metadata
`{ type: "model_changed", from: string | null, to: string | null,
fromProvider: string, toProvider: string }`. `from` and `to` are spawn-resolved
raw model ids without a provider prefix, and `nil` means "provider default
model". The row is transcript-only (never replayed to providers). It renders as
a centered informational chip, not the amber warning banner. Web parity:
`model-change-notice.ts`.

The notice is discriminated only on `metadata.type == "model_changed"`, so the
client tolerates the exact role the daemon persists (non-user and non-assistant
by contract). Absent or malformed metadata returns `nil`, and those rows keep
the generic system banner (web parity: `getModelChangeNotice`).

The label is "Switched from <side> to <side>", or the row's text content when
either side cannot be described from the metadata (web parity:
`formatModelChangeLabel`). The side format is intentionally simpler than the
web strings: "<modelId> (<provider name>)" instead of
"<pretty name> (<providerId> / <modelId>)", because iOS has no model catalog to
resolve pretty names from. `fallbackLabel` is the last resort when the metadata
and the row text are both empty (web parity:
`chat_modelChangeNotice_fallback_label`).

### 4. Questions-dismissed notices

Applies to: `QuestionsDismissedNotice`, `ConversationMessage.questionsDismissedNotice`

When the user dismisses an agent's pending questions (`agent.dismissQuestions`,
PROTOCOL §5.5), intentd delivers a system-origin message ("User dismissed your
N questions without answering…") tagged with
`{ type: "questions_dismissed", source: "system", dismissedQuestionsMessageId }`
on the row's `metadata` and on the persisted text block's `messageMetadata`.
The transcript renders it as a compact divider chip instead of a plain user
bubble. Web parity: `questions-dismissed-notice.ts` and
`QuestionsDismissedNotice.svelte`.

The lookup checks the row's `metadata` first and then the text blocks'
`messageMetadata`, and tolerates the exact role the daemon persists (web
parity: `getQuestionsDismissedNotice`). `fullText` is the full delivered text,
surfaced for accessibility and long-press.

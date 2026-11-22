# ADR-0122: Transcript notice and wake cards

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `AttentionNoticeView` (`Intent/Views/Conversation/Notices/AttentionNoticeView.swift`), `TurnFailureNoticeView`, `TurnFailureMessageParser` (`Intent/Views/Conversation/Notices/TurnFailureNoticeView.swift`), `ModelChangeNoticeView` (`Intent/Views/Conversation/Notices/ModelChangeNoticeView.swift`), `QuestionsDismissedNoticeView` (`Intent/Views/Conversation/Notices/QuestionsDismissedNoticeView.swift`), `SystemNoticeBannerView` (`Intent/Views/Conversation/Notices/SystemNoticeBannerView.swift`), `NewMessagesDividerView` (`Intent/Views/Conversation/Notices/NewMessagesDividerView.swift`), `WakeCardDisclosureHeader`, `WakeCardHeaderRow` (`Intent/Views/Conversation/Notices/WakeCardDisclosureHeader.swift`), `PrMonitorWakeAttributionView` (`Intent/Views/Conversation/Notices/PrMonitorWakeAttributionView.swift`), `ScriptMonitorWakeAttributionView` (`Intent/Views/Conversation/Notices/ScriptMonitorWakeAttributionView.swift`), `AgentMessageAttributionView` (`Intent/Views/Conversation/Notices/AgentMessageAttributionView.swift`), `CapHeightIconSlot` (`Intent/Views/Conversation/Notices/CapHeightIconSlot.swift`)

## Context

The daemon persists non-chat rows in the transcript: attention requests, model
changes, question dismissals, interruption notices and automated wakes. The app
renders each kind as a distinct card or divider, following the web client
(cloudlands-fe).

## Decisions

### 1. Attention notices

Applies to: `AttentionNoticeView`

`AttentionNoticeView` is the kind-flavored card for daemon-persisted
attention-request rows (PROTOCOL §5.5): amber for a discussion request, red for
a blocker report or a terminal turn failure. It is the visual sibling of
cloudlands-fe's `DiscussionRequestNotice.svelte`,
`BlockerReportNotice.svelte` and `TurnFailureNotice.svelte`. Turn failures
delegate to `TurnFailureNoticeView`.

### 2. Turn failure card

Applies to: `TurnFailureNoticeView`, `TurnFailureMessageParser`

The `turn-failure` attention card shows a friendly title and message from
`TurnFailureSummary`, an optional retry hint and provider link, and the
untouched reason behind a collapsed "Details" disclosure with Copy. The legacy
and workspace transcript designs render it the same way; only the body type
size follows the active design.

1. Details start collapsed. A row holds one notice, so the row's shared
   `.attentionNotice` disclosure slot is free for this card.
2. The tint is amber for a usage limit (the user did nothing wrong and can wait
   it out) and red for every real failure, matching the blocker card.
3. The message uses Textual's selectable text, because the row's Copy overlay
   passes link taps through to it. Plain `Text` links are swallowed by the
   overlay. Links use the underlined body color, not the system accent, on the
   tinted card.
4. The summary uses `.contain` rather than `.combine` accessibility, so an
   inline link stays its own VoiceOver and UI-test element. Title and message
   still read in order.
5. `hasInlineLink`: when `linkURL` is tappable in place inside the message, it
   gets no separate row below.
6. `visibleRetryHint` shows the provider's reset phrase only when the message
   does not already say it.
7. Secondary text is a neutral color that sits on the amber or red card
   without borrowing the app accent. It uses the full foreground under
   increased contrast.
8. Raw details use a language without hyphenation data (`zxx`), so tokens such
   as "usageLimitExceeded" do not break with an inserted hyphen.
9. `TurnFailureMessageParser` shows plain message text with `linkURL` linked
   where its text appears. It parses no Markdown, so provider text is shown
   exactly as sent.

### 3. Divider chips and system banners

Applies to: `ModelChangeNoticeView`, `QuestionsDismissedNoticeView`, `SystemNoticeBannerView`, `NewMessagesDividerView`

1. `ModelChangeNoticeView` is a centered inline divider chip for
   daemon-persisted model-change rows (metadata `{ type: "model_changed",
   from, to, fromProvider, toProvider }`). Its informational styling is
   distinct from chat bubbles and from the amber warning banner, because the
   row was never sent to the provider (FE parity: `ModelChangeNotice.svelte`).
   `fallbackText` is the row's text content, used when the metadata fields are
   absent.
2. `QuestionsDismissedNoticeView` is a centered inline divider chip for
   daemon-delivered dismissal rows (metadata `{ type: "questions_dismissed",
   … }`, `agent.dismissQuestions`). It is distinct from user and assistant
   bubbles. The row informs the model that the user dismissed its pending
   questions without answering (FE parity:
   `QuestionsDismissedNotice.svelte`).
3. `SystemNoticeBannerView` is a generic muted banner for system-role rows
   that are not classified attention notices, for example
   `meta.kind = "interruption"` restart notices or unknown future kinds, so
   they still render instead of disappearing (FE parity:
   `InterruptionNotice.svelte`, the `ChatMessage.svelte` system-branch
   fallback). An empty `message` falls back to the default restart notice.
4. `NewMessagesDividerView` is a presentation-only "New messages" unread
   marker (FE parity: `NewMessagesDivider.svelte`): hairline, envelope and
   caption, hairline. It is never part of the transcript. The transcript view
   (`ConversationTranscriptView+Presentation.swift`) renders it directly after
   the session's latched divider anchor message.

### 4. Wake cards

Applies to: `WakeCardDisclosureHeader`, `WakeCardHeaderRow`, `PrMonitorWakeAttributionView`, `ScriptMonitorWakeAttributionView`

1. `WakeCardDisclosureHeader` is the collapsible header for hook, PR-monitor
   and script-monitor wake cards. The body stays hidden until expanded (FE
   parity: `AutomatedWakeCardHeader`, collapsed by default). A header without
   its own controls makes the whole row one button. A header with its own
   control (the PR chip) keeps it and gets a separate chevron button, because
   buttons cannot nest.
2. `WakeCardHeaderRow` shows the icon plus title and status lines. The text is
   measured from the title's cap top to the last baseline, so the card padding
   reads evenly, and the icon centres on the title's first line.
3. `PrMonitorWakeAttributionView` is the compact attribution header for
   centralized PR-monitor wake messages (`metadata.type == "pr_monitor_wake"`,
   PROTOCOL §5.42): a pull-request icon, a tappable PR chip and "woke the
   agent". It follows `HookWakeAttributionView`, but the chip opens the PR in
   the browser (metadata `url` first, GitHub fallback; gated by the
   `ExternalLink` http/https allowlist). It is the iOS counterpart of
   cloudlands-fe's `PrMonitorWakeAttributionHeader`. `workspaceRepo` is the
   `<owner>/<repo>` of the conversation's workspace, or nil when unknown; the
   chip label then falls back to the bare `#<n>` form.
4. `ScriptMonitorWakeAttributionView` is the header for script-monitor wake
   rows: a terminal icon, the script name and the monitor outcome (FE parity:
   `AutomatedWakeCardHeader` script kind).

### 5. Agent message attribution keeps two tap targets

Applies to: `AgentMessageAttributionView`

Sender navigation and message disclosure stay separate tap targets.

### 6. Icons centre on the capitals of the first text line

Applies to: `CapHeightIconSlot`, `Constants.Typography.Style.capHeight(size:legibilityWeight:)`

`CapHeightIconSlot` is a slot as tall as a text style's cap height that
centres its icon on it. Bottom-aligned to a first text baseline (or
top-aligned to a cap top), the icon centres on that line's capitals and does
not change the row height. `capHeight` measures the cap height at a scaled
point size, using the face that Bold Text renders.

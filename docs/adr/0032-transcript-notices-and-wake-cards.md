# 0032. Transcript notices and wake cards

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The daemon persists rows that are not chat messages: attention requests, turn failures, model changes, dismissed questions, interruptions, and automated wakes from hooks, PR monitors and script monitors. The desktop app (cloudlands-fe) renders each kind with its own component. The phone must match it. [ADR 0054](0054-transcript-attribution-and-notices.md) decides how a row is classified; this record decides how each kind renders. Rows in the transcript have a Copy overlay that swallows plain taps.

## Decision

1. **Desktop parity.** Each row kind has its own view, matched to the desktop component.
   1. `AttentionNoticeView` (PROTOCOL §5.5): amber for a discussion request, red for a blocker report or a terminal turn failure. It delegates turn failures to `TurnFailureNoticeView`. Desktop: `DiscussionRequestNotice`, `BlockerReportNotice`, `TurnFailureNotice`.
   2. `ModelChangeNoticeView` (`model_changed` metadata) and `QuestionsDismissedNoticeView` (`questions_dismissed`, `agent.dismissQuestions`) are centered divider chips, distinct from chat bubbles and from the amber warning banner. These rows were never sent to the provider as user text. Desktop: `ModelChangeNotice`, `QuestionsDismissedNotice`.
   3. `SystemNoticeBannerView` renders every other system row, such as `interruption` restart notices and unknown future kinds, so a row never disappears. Desktop: `InterruptionNotice` (the system fallback in `ChatMessage`).
   4. `NewMessagesDividerView` is presentation only. It is never part of the transcript. `ConversationView` draws it after the latched divider anchor message. Desktop: `NewMessagesDivider`.
2. **Turn failures.**
   1. `TurnFailureNoticeView` shows a friendly title and message from `TurnFailureSummary`, an optional retry hint and provider link, and the untouched reason in a collapsed Details disclosure with Copy. The legacy and workspace designs render it the same way; only the body type size changes.
   2. The tint is amber for a usage limit (the user can wait it out) and red for every real failure, as on the blocker card.
   3. The message is plain text. It is not parsed as Markdown, so provider text shows exactly as sent. Only `linkURL` is linked where its text appears (`TurnFailureMessageParser`).
   4. The message uses Textual's selectable text, because the row's Copy overlay passes link taps through to it. Plain `Text` links are swallowed by the overlay.
   5. The card uses `.accessibilityElement(children: .contain)`, so an inline link stays its own VoiceOver and UI-test element.
   6. The Details text uses a language without hyphenation data (`zxx`), so tokens such as `usageLimitExceeded` do not break with a hyphen.
3. **Wake cards.**
   1. Hook, PR-monitor and script-monitor wake cards are collapsed by default (desktop: `AutomatedWakeCardHeader`). `WakeCardDisclosureHeader` makes the whole header one button, unless the header has its own control. The PR chip keeps its own button and gets a separate chevron, because buttons cannot nest.
   2. `PrMonitorWakeAttributionView` (`pr_monitor_wake`, PROTOCOL §5.42) opens the PR in the browser. It uses the metadata `url` first and the GitHub URL as fallback, through the `ExternalLink` http/https allowlist.
   3. `ScriptMonitorWakeAttributionView` shows the script name and the monitor outcome.
   4. In `AgentMessageAttributionView`, sender navigation and message disclosure are separate tap targets.
4. **Icon alignment.** `CapHeightIconSlot` is as tall as the text style's cap height, so an icon centers on the first line's capitals without changing the row height.
5. **Row dispatch.** `MessageView` checks metadata before the role, as the desktop `ChatMessage` does. A `questions_dismissed` row and a `model_changed` row render as divider chips whatever their persisted role. A user-role event-notification wake renders as `EventWakeBannerView`, because its whole body is machine text (desktop: `EventWakeupBanner`). A system row with an attention notice renders as `AttentionNoticeView`; every other system row renders as `SystemNoticeBannerView`. Agent-to-agent rows and automated wake cards start collapsed (desktop: `isAgentMessageExpanded`, `isAutomatedWakeExpanded`).

## Consequences

- A new daemon row kind renders through `SystemNoticeBannerView` until it gets its own view.
- A link inside a transcript notice must use Textual text, not `Text`, or the Copy overlay swallows it.

## Code

- `AttentionNoticeView`, `TurnFailureNoticeView`: `tint`, `TurnFailureMessageParser`
- `ModelChangeNoticeView`, `QuestionsDismissedNoticeView`, `SystemNoticeBannerView`, `NewMessagesDividerView`
- `WakeCardDisclosureHeader`, `WakeCardHeaderRow`, `PrMonitorWakeAttributionView`, `ScriptMonitorWakeAttributionView`, `AgentMessageAttributionView`
- `CapHeightIconSlot`
- `MessageView`, `MessageRowContent`, `UserMessageView`, `EventWakeBannerView`

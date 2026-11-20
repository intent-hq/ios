# 0031. visionOS floating composer and coverage

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

On visionOS the chat composer floats in a glass ornament below the window. A window can show several chats: a pushed child agent, the Assistant sheet over a chat, or the open Intent menu. Before this rule, the Assistant sheet over a chat showed two composers. A photo import can be in flight when the composer hides.

## Decision

1. **Host.** `ComposerHost` is `floating` only on visionOS. Every iOS presentation keeps the composer inline at the bottom of the column. The rules live in the platform-neutral `FloatingComposerPolicy` so the iOS unit-test host can test them. Only `FloatingComposerOrnament` is visionOS-specific.
2. **One composer per window.**
   1. The floating composer shows under the same conditions as the inline one: not while the transcript loads, and only when the question slot leaves the composer available.
   2. It shows only for the chat in front. A pushed child agent withdraws it (`isActiveChat`). A covering modal layer hides it (`isForemost`, from `ComposerCoverage`).
   3. `ComposerCoverage` counts covering layers per window. Each layer sits one level above the view that presented it (`composerLayerDepth`). A composer is foremost only when no active layer sits above its level.
   4. Sheets and full-screen covers mark themselves with `coversConversationComposers()`. In-window overlays such as the open Intent menu use `coversConversationComposers(while:)`.
3. **Covered versus withdrawn.**
   1. `covered` is temporary. The composer hides (no input, focus or accessibility), but drafts, pending attachments and in-flight photo imports stay, and the composer returns when the layer goes.
   2. `withdrawn` means the chat went away (navigation, loading, question slot). It cancels the in-flight photo import, as when the inline composer unmounts.
   3. A covered or withdrawn composer is unmounted, so no Send button is visible or reachable by VoiceOver, and `onDisappear` stops dictation and focus. On visionOS, unmounting does not cancel the photo import; only `onWithdraw` does.
   4. `FloatingComposerLifecycle` is the one state machine for these transitions. The modifier and the unit tests use the same code. `.onDisappear` followed by `.onChange` cancels a photo import once, never twice.
4. **Geometry.** The ornament width tracks the chat column, between `minimumWidth` and `maximumWidth`, and is never wider than the column. The glass corner radius is the field capsule radius plus the row padding and `contentInset`, so the curves stay concentric. The ornament hangs below the window's bottom edge (`.scene(.bottom)`).
5. **Launcher clearance.** `questionRegionLauncherTop(…)` reports the top edge that the workspace action launcher must stay above. Inline hosts report it only when the question slot replaces the composer. With a floating composer, the question region and the status rows above it are the lowest in-window controls, so the launcher stays above them. An empty region reports nothing rather than a stale top.
6. **Dictation.** visionOS dictation is an app-owned Speech session that inserts at the caret (`caretOffset`). [ADR 0102](0102-dictation-merge-rules.md) has the merge rules.
   1. `isActive` includes the start window. A second tap while permission prompts are open cancels the start before any audio.
   2. The view tracks the committed insertion point, because programmatic text changes do not always fire a selection change.
   3. When the text changes outside dictation (typing, or a send that clears it), that edit wins and dictation stops.
   4. A send stops dictation before it reads the text, so a late final result cannot bring the sent text back.
7. **Suggested prompts** on visionOS are large chips above the field, sized for gaze (at least 60 pt). The transcript's inline prompt list is off on visionOS.
8. **Hover.** The text view's hover effect uses the field's rounded corners (`hoverStyle`), because the outer SwiftUI clip does not shape it.
9. **No launcher gap** (from test comments). The transcript keeps no launcher-tall padding under the last row; the launcher floats over it. The bottom padding (`bottomAnchorPadding`) sits on the end marker, so follow landings still reach the true end.
10. **Source wiring tests** (from test comments). visionOS branches cannot run in the iOS test host, so `FloatingComposerPolicyTests` checks the wiring in source: exactly two `MessageInputView` construction sites (the inline host, gated off on visionOS, and the ornament host), and every modal that can open over a chat registers as a covering layer.

## Consequences

- A new modal surface on visionOS must call `coversConversationComposers()`, or two composers show.
- iOS behavior does not change; the iOS host is always `inline`.

## Code

- `ComposerHost`, `FloatingComposerPresentation`, `FloatingComposerPolicy`: `presentation(…)`, `cancelsPhotoImport(from:to:)`, `width(forColumnWidth:)`, `questionRegionLauncherTop(…)`, `cornerRadius`
- `FloatingComposerLifecycle`: `appear(…)`, `applyPresentation(_:)`, `disappear()`
- `FloatingComposerOrnament`: `onWithdraw`, `lifecycle`
- `ComposerCoverage`: `isForemost(depth:)`, `composerLayerDepth`, `coversConversationComposers()`, `coversConversationComposers(while:)`
- `MessageInputView`: `dictationButton`, `suggestedPromptChipsRow`
- `SubmittableTextView`: `hoverCornerRadius`

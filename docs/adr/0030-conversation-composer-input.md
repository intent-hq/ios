# 0030. Conversation composer input and send

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

The composer wraps a `UITextView` in SwiftUI. SwiftUI renders from snapshots, and UIKit editing callbacks write bindings later. A stale read can replace newer text or focus. The same composer serves iPhone, iPad and visionOS, and each platform has its own Return-key convention. A send can also start while files are still uploading.

## Decision

1. **One draft.** `MessageInputView` binds directly to `ConversationViewModel`. Received edits and external replacements share one draft. Deferred two-way `onChange` copies are not used, because they can replay old text.
2. **Deferred native sync.**
   1. `synchronizeText(in:)` reads the binding after the update pass, through the current parent. An edit received meanwhile is not replaced by an older render snapshot (ios#575).
   2. `synchronizeFocus(in:)` reads focus after the deferred binding writes. If UIKit changes focus before the block runs, the newer UIKit change wins (`nativeFocusRevision`, ios#799).
   3. To end editing while a panel is open, the composer resigns focus. It does not disable the editor, because UIKit restores a disabled first responder when the panel closes.
3. **Return key (`ComposerSubmitPolicy`).** Shift+Return always inserts a newline.
   1. iPad: bare Return submits.
   2. iPhone: bare Return inserts a newline. The Send button sends.
   3. visionOS: bare Return submits only while a hardware keyboard is connected (`GCKeyboard.coalesced`). The virtual keyboard inserts a newline.
   4. Hardware bare Return goes through a `UIKeyCommand`. Hardware Shift+Return and software Return reach the text view delegate, which checks `isShiftHeld`.
4. **Send.**
   1. `isConnectionReadyForSending` is read live at both submission boundaries, before and after the run-loop hop, before the draft is consumed.
   2. The send re-checks `isUploadingFiles` and `isLoadingPhotos`. The submit callback can arrive while the Send button is disabled, and pending files clear only after success, so a second send would upload the files twice.
   3. Sending ends editing on every device. Only an explicit tap opens it again.
5. **Image paste.** `canPerformAction(_:withSender:)` checks pasteboard metadata only. The app never reads clipboard contents on focus or render. Edit-menu Paste and Command-V are the same explicit user action.
6. **Text styling.** The font token already applies `UIFontMetrics`, so the text view does not scale it again (`adjustsFontForContentSizeCategory = false`). A UITextView has no placeholder to announce, so the composer sets its `accessibilityLabel`.
7. **Skill suggestions.** `ComposerSkillCompletion.matches` reads `catalog.skills` and `context`, so observers stay subscribed to both. The ranked result is memoized, so repeated reads in one render do not rank the catalog again. `SkillSuggestionsView` is a horizontal chip row; Return or a tap inserts the highlighted chip.
8. **Workspace design.** `WorkspaceComposerRow` and `WorkspaceQueuedMessagesView` only present. The conversation owner keeps the draft, attachments, send and queue commands. Each queue action keeps a 44 pt hit region without moving the reference glyph spacing. `WorkspaceQueuePanel` wraps the composer without changing its identity when the queue appears or disappears.
9. **Loading and errors.**
   1. The caller of `ConversationConnectionStatusBlock` owns the start date, so stage changes and manual retries keep one elapsed clock.
   2. The compact Assistant keeps its sheet and actions while its thread list loads (`AssistantStateContent`).
   3. A remote read-only drop is not an error in `AssistantView`. The read-only banner covers it.

## Consequences

- A new submit path must check connection and upload state again at the point where it consumes the draft.
- Code that writes composer text or focus from SwiftUI must go through the deferred sync, not set the text view directly.

## Code

- `MessageInputView`: `viewModel`, `caretOffset`, `isConnectionReadyForSending`, `sendCurrentMessage()`
- `SubmittableTextView.Coordinator`: `synchronizeText(in:)`, `synchronizeFocus(in:)`, `nativeFocusRevision`
- `KeyCommandTextView`: `canPerformAction(_:withSender:)`, `paste(_:)`, `isShiftHeld`, `returnSubmitsNow`
- `ComposerSubmitPolicy`, `ComposerSkillCompletion`: `matches`, `SkillSuggestionsView`
- `WorkspaceComposerRow`, `WorkspaceComposerSurface`, `WorkspaceQueuedMessagesView`, `WorkspaceQueuePanel`
- `ConversationConnectionStatusBlock`, `AssistantStateContent`, `AssistantView`

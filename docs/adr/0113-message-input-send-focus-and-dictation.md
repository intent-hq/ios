# ADR-0113: MessageInputView owns send, focus and visionOS dictation rules

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `MessageInputView` (`Intent/Views/Conversation/Composer/MessageInputView.swift`)

## Context

`MessageInputView` is the shared chat composer. It binds the draft, gates send
on the connection, manages focus, imports photos and files, and on visionOS
runs app dictation and shows suggested prompts. The send path must not
duplicate uploads or resurrect sent text.

## Decisions

### 1. The view binds directly to the view model's draft

Applies to: `MessageInputView.viewModel`

The view binds to the model, so received edits and external replacements share
one draft. Deferred bidirectional `onChange` copies can replay old text.

### 2. Send reads the live connection state at both submission boundaries

Applies to: `MessageInputView.isConnectionReadyForSending`, `MessageInputView.sendCurrentMessage()`

`isConnectionReadyForSending` reads live connection state. `sendCurrentMessage`
checks it before and after the deferred block, before it consumes the draft.

### 3. The photo picker sizes from the remaining image slots

Applies to: `MessageInputView.body` (`photosPicker`)

Earlier picks stay pending after import. The picker's maximum selection count
and filter come from the remaining image slots
(`photoPickerMaxSelectionCount`, `photoPickerFilter`).

### 4. Opening the question panel resigns focus explicitly

Applies to: `MessageInputView.body` (`onChange(of: questionPanelPresented)`)

The view resigns focus rather than disabling the native editor. UIKit restores
a disabled first responder when the panel closes.

### 5. The send path guards against duplicate uploads and keeps images for the async send

Applies to: `MessageInputView.sendCurrentMessage()`

1. System dictation is committed before the final text is read. When the active
   input mode is dictation, the view resigns focus to stop dictation and commit
   the final text.
2. The visible send button is disabled while a send places files, but the text
   view's submit callback still reaches `sendCurrentMessage`. `pendingFiles`
   clears only after success, so a second send would duplicate the uploads. The
   deferred block therefore checks `isUploadingFiles` and `isLoadingPhotos`
   again.
3. Pending images are captured before the draft is cleared, so they are still
   available for the async send.
4. Sending ends editing on every device. Only an explicit tap reopens it.

### 6. visionOS app dictation

Applies to: `MessageInputView.caretOffset`, `MessageInputView.dictationButton`, `MessageInputView.toggleDictation()`, `MessageInputView.sendCurrentMessage()`

1. The dictation button starts a live Speech-framework session that inserts
   transcriptions at the caret. Tapping again stops and keeps the final
   result.
2. `caretOffset` is the last observed caret offset. Dictation treats nil as end
   of text.
3. `dictation.isActive` covers the starting window too. A second tap while the
   permission prompts are pending cancels the start before any audio.
4. Programmatic text sets do not reliably fire a selection change, so the
   observed caret can be stale. When a segment ends, the view tracks the
   committed insertion point, so a re-tap after the recognizer finishes appends
   instead of replacing.
5. When the composer text was edited outside dictation (typed, or replaced by
   the view model, for example a send cleared it), the edit wins. Dictation
   stops instead of overwriting it.
6. `sendCurrentMessage` stops app dictation before the text is consumed. A late
   final result must not resurrect the sent text. The `.send` reason cancels
   outright.

### 7. visionOS suggested prompts are chips above the field

Applies to: `MessageInputView.suggestedPromptChipsRow`

Suggested prompts show as large chips directly above the field, sized for gaze
targeting (at least 60 pt). The transcript's inline prompt list is disabled on
visionOS in favor of these.

## Consequences

A new submit path must check connection and upload state again at the point
where it consumes the draft.

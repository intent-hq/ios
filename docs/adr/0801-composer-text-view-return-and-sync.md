# ADR-0801: The composer text view decides Return per platform and syncs SwiftUI state after each update pass

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ComposerSubmitPolicy`, `KeyCommandTextView`, `SubmittableTextView` (`Intent/Views/Conversation/Composer/SubmittableTextView.swift`)
- Related issues: ios#575, ios#799

## Context

The chat composer is a `UITextView` subclass, `KeyCommandTextView`, wrapped
for SwiftUI by `SubmittableTextView`. It must decide when Return sends the
message, paste images without reading the clipboard early, size itself for the
SwiftUI height clamp, and keep its text and focus in step with SwiftUI
bindings.

## Decisions

### 1. Bare Return submits on iPad, never on iPhone, and on visionOS only with a hardware keyboard

Applies to: `ComposerSubmitPolicy.returnSubmits(isVisionOS:idiom:hasHardwareKeyboard:)`, `KeyCommandTextView.returnSubmitsNow`, `KeyCommandTextView.keyCommands`

Shift+Return always inserts a newline.

1. visionOS is dictation-first. Return submits only while a hardware keyboard
   is connected (`GCKeyboard.coalesced`). The virtual keyboard's Return
   inserts a newline, so the composer sends with the button.
2. iPad: Return always submits.
3. iPhone: Return always inserts a newline. The user sends with the button
   only.

`keyCommands` does not intercept Return where it must insert a newline (iPhone
always, visionOS without a hardware keyboard). It still returns the skill
completion commands in that case.

### 2. Hardware bare Return goes through a key command; Shift+Return and software Return go through the delegate

Applies to: `KeyCommandTextView`, `KeyCommandTextView.isShiftHeld`, `SubmittableTextView.Coordinator.textView(_:shouldChangeTextIn:replacementText:)`

`KeyCommandTextView` intercepts hardware Return to submit and lets Shift+Return
insert a newline. Hardware bare Return is handled by a `UIKeyCommand` and never
reaches the delegate. Hardware Shift+Return bypasses the key command and
arrives in the delegate. The text view tracks whether Shift is held
(`isShiftHeld`, from `pressesBegan`, `pressesEnded` and `pressesCancelled`), so
the delegate can tell Shift+Return (newline) from software keyboard Return
(submit, where the submit rule allows it).

### 3. `keyCommands` stays optional because UIKit requires it

Applies to: `KeyCommandTextView.keyCommands`

UIKit requires this override to remain optional. Nil means no commands. This is
why the `discouraged_optional_collection` lint rule is disabled on it.

### 4. Image paste reads pasteboard metadata only until the user pastes

Applies to: `KeyCommandTextView.canPerformAction(_:withSender:)`, `KeyCommandTextView.paste(_:)`

`canPerformAction` checks metadata only. It never reads clipboard contents on
focus or render. Edit-menu Paste and Command-V share `paste(_:)`, which is the
explicit user action that reads the images.

### 5. Typography resolves from current traits without UIKit rescaling

Applies to: `KeyCommandTextView.configureTypography()`, `KeyCommandTextView.updateTypography()`

The typography token already applies `UIFontMetrics`. The view resolves the font
from current traits and sets `adjustsFontForContentSizeCategory = false`, so
UITextView does not scale the scaled font again.

### 6. `naturalHeight` ignores the live centering inset

Applies to: `KeyCommandTextView.naturalHeight`, `KeyCommandTextView.centerShortContent()`

`naturalHeight` is the content height measured with the base container inset,
independent of the live vertical-centering inset. The SwiftUI height clamp
therefore sees a stable value while `centerShortContent()` centers short text
in the minimum field height.

### 7. SwiftUI inputs that the text view needs

Applies to: `SubmittableTextView.onCaretChange`, `SubmittableTextView.hoverCornerRadius`, `SubmittableTextView.accessibilityLabel`, `SubmittableTextView.textColor`, `SubmittableTextView.makeUIView(context:)`

1. `onCaretChange` reports the caret's UTF-16 offset (end of selection) on every
   selection change. visionOS dictation uses it to insert at the caret.
2. `hoverCornerRadius` is the corner radius of the visionOS hover and highlight
   shape. It defaults to the composer field's corners. On visionOS
   `makeUIView` sets `hoverStyle` to that rounded shape. The system default
   rect shape draws a rectangle inside the rounded field, and the outer
   `RoundedRectangle` clip in `MessageInputView` does not affect it.
3. `accessibilityLabel` is the VoiceOver label for the text view. UITextView
   has no placeholder to announce, so a SwiftUI placeholder overlay does not
   label it.
4. `textColor` is an opt-in foreground for a scoped composer design. Nil keeps
   UIKit's existing color without rewriting attributed text or changing the
   editing policy.

### 8. The coordinator reads bindings after the update pass

Applies to: `SubmittableTextView.updateUIView(_:context:)`, `SubmittableTextView.Coordinator.synchronizeText(in:)`, `SubmittableTextView.Coordinator.synchronizeFocus(in:)`, `SubmittableTextView.Coordinator.nativeFocusRevision`

`updateUIView` keeps the coordinator's `parent` current, so the coordinator's
closures (for example `onCaretChange`) capture the latest state.

A binding read during `updateUIView` can be an older render snapshot.
`synchronizeText` reads the text after that pass, through the current parent,
so an edit received meanwhile cannot be replaced by that snapshot (ios#575).

Native editing callbacks defer their binding writes. `synchronizeFocus` reads
the focus after those writes, not the render snapshot that preceded them. If
UIKit changes focus before the deferred block runs, that newer transition wins,
even when its binding write is still queued behind the block (ios#799).
`nativeFocusRevision` detects this.

## Consequences

Code that writes composer text or focus from SwiftUI must go through this
deferred sync, not set the text view directly.

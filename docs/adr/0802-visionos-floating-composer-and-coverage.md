# ADR-0802: visionOS hosts one floating composer per window, hidden by covering layers

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ComposerHost`, `FloatingComposerPresentation`, `FloatingComposerPolicy`, `FloatingComposerLifecycle` (`Intent/Views/Conversation/Composer/FloatingComposerPolicy.swift`), `FloatingComposerOrnament` (`Intent/Views/Conversation/Composer/FloatingComposerOrnament.swift`), `ComposerCoverage`, `coversConversationComposers()` (`Intent/Views/Conversation/Composer/ComposerCoverage.swift`), `MessageInputView` (`Intent/Views/Conversation/Composer/MessageInputView.swift`)

## Context

On visionOS a chat's composer floats in a glass ornament below the window. A
window can hold several chats (a pushed child agent, the Assistant sheet over a
chat), and each one has a composer. Only one composer may show, and hiding a
composer must not lose its draft or an in-flight photo import.

## Decisions

### 1. visionOS floats the composer; iOS keeps it inline

Applies to: `ComposerHost.forPlatform(isVisionOS:)`

visionOS hosts the composer in a bottom ornament just outside the window. Every
iOS presentation keeps it inline at the bottom of the column, unchanged.

### 2. Presentation has three states; only withdrawal cancels a photo import

Applies to: `FloatingComposerPresentation`, `FloatingComposerPolicy.cancelsPhotoImport(from:to:)`

1. `covered`: hidden while a modal layer covers the chat. This is temporary. An
   in-flight photo import keeps running, so its attachment is waiting when the
   modal is dismissed.
2. `shown`: visible, interactive and exposed to accessibility. The chat is in
   front.
3. `withdrawn`: the chat went away (navigation, loading, question slot). An
   in-flight photo import is cancelled, as when the inline composer unmounts.

Only a real withdrawal cancels the import. Being covered by a modal does not.

### 3. The floating composer shows under the inline conditions, and only for the chat in front

Applies to: `FloatingComposerPolicy.presentation(isActiveChat:isForemost:showsLoadingState:composerVisible:)`

The floating composer appears under the same conditions as the inline one: not
while the transcript is loading, and only when the question slot leaves the
composer available. It also shows only for the chat in front. A pushed child
agent (`isActiveChat`) withdraws it. A covering modal layer such as the
Assistant sheet (`isForemost`, from `ComposerCoverage`) hides it. Each window
therefore shows exactly one composer.

### 4. The rules are platform-neutral so iOS unit tests can pin them

Applies to: `FloatingComposerPolicy`, `FloatingComposerLifecycle`

`FloatingComposerPolicy` holds the presentation rules without platform guards,
so the iOS unit-test host can pin them. Only the ornament itself is
visionOS-specific (`ConversationColumnView`).

`FloatingComposerLifecycle` is the stateful machine that
`FloatingComposerOrnament` owns. Unit tests exercise the same presentation and
disappear transitions, rather than re-implementing the view modifier's
branching. `sync` and `updateActiveChat` return true when an in-flight photo
import must be cancelled. `applyPresentation` deduplicates against
`disappear()`, and `disappear()` marks the chat inactive and returns true only
once, when the composer was not already withdrawn. So `.onDisappear` followed
by a trailing `.onChange` never cancels a photo import twice.
`FloatingComposerOrnament` keeps `cancelsPhotoImport` delegated through
`lifecycle.applyPresentation` for this reason.

### 5. Geometry constants

Applies to: `FloatingComposerPolicy.horizontalMargin`, `minimumWidth`, `maximumWidth`, `contentInset`, `cornerRadius`, `width(forColumnWidth:)`

1. `horizontalMargin` (24) is the gap between the ornament and each side of the
   chat column.
2. `minimumWidth` (320) is the narrowest composer before it stops shrinking
   with the column.
3. `maximumWidth` (760) is the widest composer. It matches a comfortable
   reading measure on wide windows.
4. `contentInset` (10) is the inset between the glass edge and the composer.
   It keeps pending attachment previews clear of the rounded corners.
5. `cornerRadius` (48) is the 60 pt field capsule's 30 pt radius, plus the
   input row's 8 pt vertical padding, plus `contentInset`, so the field and
   container curves stay concentric.

`width(forColumnWidth:)` tracks the chat column, so resizing the window
resizes the ornament. It returns nil until the column has been measured. It is
never wider than the column itself when the window is very narrow.

### 6. Which top edge the workspace action launcher must stay above

Applies to: `FloatingComposerPolicy.questionRegionLauncherTop(host:questionInputTop:hasQuestionContent:composerVisible:usesPhoneQuestionPresentation:accessoryRowsTop:)`

The question region reports this top edge. Inline hosts report it only when the
question slot replaces the composer; otherwise the composer reports its own
top. A floating composer lives outside the window, so the question region is
the lowest in-window input whenever it shows content. An empty region reports
nothing rather than a stale top.

`accessoryRowsTop` is the top of the status rows above the question region
(agent waiting, PR monitors, hooks, queue), when any show. With a floating
composer these rows are the window's bottom controls, so the launcher stays
above them. Inline hosts keep the prior rule.

### 7. The ornament reuses `MessageInputView` and only decides placement

Applies to: `FloatingComposerOrnament`, `MessageInputView`

The ornament hosts the shared `MessageInputView`, so its draft, pending
attachments, uploads, dictation and send rules are the inline ones. The
modifier only decides placement, size and visibility.

1. `onWithdraw` cancels the chat's in-flight photo import. It is called on a
   real withdrawal only, never because a modal covers the chat. On visionOS
   `MessageInputView` does not cancel the import in `.onDisappear`;
   `onWithdraw` does it.
2. `lifecycle.isActiveChat` is false while another chat is pushed over this
   one, so only the chat in front owns the window's composer. Sheets and
   full-screen covers do not end appearance; `ComposerCoverage` handles those.
3. Covered or withdrawn composers are unmounted. There is no visible or
   VoiceOver-reachable Send, and `onDisappear` stops dictation and focus.
   Unmounting does not cancel the photo import (see `onWithdraw`).
4. The ornament is centered under the window's bottom edge (HIG ornament
   placement). Its top aligns there, so it hangs just outside the window.
5. Under Reduce Transparency an opaque surface replaces see-through glass.
6. `MessageInputView` draws `Color.clear` behind the legacy design on visionOS,
   because the floating ornament host supplies the glass.

### 8. The ornament alignment type depends on the SDK

Applies to: `FloatingComposerOrnament.ornamentAlignment`

Xcode 27 replaces the public 2D ornament overload with a back-deployed 3D one,
so `compiler(>=6.4)` uses `Alignment3D`. Earlier SDKs require `Alignment` to
support the visionOS 2 minimum.

### 9. `ComposerCoverage` tracks covering layers by depth

Applies to: `ComposerCoverage`, `EnvironmentValues.composerLayerDepth`, `ComposerConditionalCoveringLayer`, `View.coversConversationComposers()`, `View.coversConversationComposers(while:)`

`ComposerCoverage` holds the modal layers (sheets, full-screen covers) open in
one window, so a chat can tell whether something covers it. Each covering layer
sits one level above the view that presented it. `composerLayerDepth` is how
many covering modal layers enclose a view (0 for window content). A chat
composer is foremost only when no active layer sits above its own level. On
visionOS this keeps exactly one floating composer, the foremost chat's, visible
and interactive. Before this, the Assistant sheet over a chat showed two.

1. `coversConversationComposers()` marks sheet or full-screen-cover content
   that covers the chats beneath it. Their floating composers withdraw until it
   is dismissed. Drafts and pending attachments stay on the conversation model.
2. `coversConversationComposers(while:)` covers the chats beneath an in-window
   overlay, such as the open Intent menu, while `isActive`. Withdrawing it, or
   unmounting it, uncovers the chats. This coverage is temporary: covered
   composers hide (no input, focus or accessibility) but keep drafts, pending
   attachments and in-flight imports, and return on withdrawal.

# ADR-0120: Media lightboxes and shared image actions

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `ImageLightboxView` (`Intent/Views/Conversation/Content/ImageLightboxView.swift`), `ImageInfoFormat`, `ChatImageSaveOutcome`, `ChatImageSaver`, `ImageSaveAlertModel`, `ImageActionMenuItems`, `SquareImageThumbnail` (`Intent/Views/Conversation/Content/ChatImageActions.swift`), `VideoLightboxView` (`Intent/Views/Conversation/Content/VideoLightboxView.swift`), `PDFLightboxView`, `WorkspacePDFView` (`Intent/Views/Conversation/Content/PDFLightboxView.swift`), `PDFLinkPreviewView` (`Intent/Views/Conversation/Content/PDFLinkPreviewView.swift`)

## Context

Chat images, videos and PDFs open full screen. Images offer Save and Copy from
both the thumbnail context menu and the lightbox.

## Decisions

### 1. The image lightbox follows the web client

Applies to: `ImageLightboxView`, `ImageLightboxView.data`, `ImageLightboxView.clampedOffset(_:in:)`

The fullscreen image viewer has pinch-to-zoom, drag-to-pan while zoomed, a
double-tap zoom toggle, and dismissal with the close button, a backdrop tap, or
a swipe down while unzoomed (FE parity: `ImageLightbox.svelte`). An ellipsis
menu next to the close button offers Save and Copy, plus the image's
dimensions and file size.

1. `data` holds the original encoded bytes when known (base64 image blocks), so
   the info rows show the real file size.
2. While unzoomed, a vertical pull tracks the finger as dismissal feedback.
3. `clampedOffset` keeps the zoomed image edge-locked to the viewport: no
   panning past the fitted image's scaled bounds, and no panning at all while
   unzoomed.

### 2. One shared image action menu

Applies to: `ImageActionMenuItems`, `ImageActionMenuItems.originalData`, `ImageInfoFormat.dimensionsText(for:)`

`ImageActionMenuItems` holds the Save Image and Copy Image actions and the info
rows. Both the thumbnail long-press context menu and the lightbox ellipsis menu
use it (FE parity: the chat-image ellipsis menu; iOS offers Save and Copy in
place of Download and Copy path).

1. `originalData` holds the original encoded bytes when known (base64 image
   blocks). The size row falls back to a PNG re-encode of the loaded image when
   it is absent.
2. `dimensionsText(for:)` shows pixel dimensions as "W × H". `UIImage.size` is
   in points, and `scale` converts to pixels. Base64-decoded images have scale
   1.

### 3. Saving uses add-only access and reports denial separately

Applies to: `ChatImageSaver`, `ChatImageSaveOutcome`, `ImageSaveAlertModel`, `View.imageSaveAlert()`

1. `ChatImageSaver` saves to the photo library with add-only access. It pairs
   with `NSPhotoLibraryAddUsageDescription` in Info.plist. Its second `save`
   overload has seams so tests can inject authorization and write results.
2. `ChatImageSaveOutcome` keeps denial apart from other failures, so the alert
   points the user to Settings only when that helps.
3. `ImageSaveAlertModel` owns the visible Save Image outcome. Menu content is
   torn down when the menu closes, so the alert lives on the view that hosts
   the menu. Install `imageSaveAlert()` on every view whose menu contains
   `ImageActionMenuItems`.

### 4. Thumbnail size

Applies to: `SquareImageThumbnail`, `SquareImageThumbnail.transcriptSide`

`SquareImageThumbnail` is the compact cropped preview for attachment grids and
video posters. `transcriptSide` is the maximum transcript preview side; square
media cards use it too.

### 5. Video and PDF viewers retain their own file

Applies to: `VideoLightboxView.video`, `VideoLightboxView` (audio session), `PDFLightboxView.pdf`, `WorkspacePDFView`, `PDFLinkPreviewView`

1. The video and PDF lightboxes retain the file independently of the
   transcript's attachment and cache.
2. Dismissal may cancel the playback task while audio session activation is
   blocking. The video lightbox does not create a player after disappearance,
   and it releases that activation instead of leaking it.
3. `WorkspacePDFView` uses `PDFView`, which supplies native continuous
   scrolling, text accessibility and pinch zoom.
4. `PDFLinkPreviewView`: a PDF link can be opened before its bytes are cached,
   unlike an inline PDF card.

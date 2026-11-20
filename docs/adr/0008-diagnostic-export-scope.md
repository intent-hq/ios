# 0008. Diagnostic export scope and expiry

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Decision

1. `clearHistory()` runs only from the confirmed destructive action. It never touches saved connections, conversations, or copies the user already shared.
2. A preview expires. The view owns the wait in `refreshWhenExpired()` and cancels it. The writer checks expiry again at Share time, also when the preview expires during ZIP preparation.
3. A dismissed export never opens a late share sheet and never shows a failure.
4. `DiagnosticExportView` has no backend or session environment dependency, so every entry point works offline.
5. UIKit retains the share sheet's completion handler, and the lease it captures, for the consumer's lifetime, also after SwiftUI removes the presenting view. The handler logs no foreign error, returned item, activity identifier or URL.

## Code

- `DiagnosticExportModel`: `clearHistory()`, `refreshWhenExpired()`, `start(_:)`
- `DiagnosticExportView`, `DiagnosticShareSheet`

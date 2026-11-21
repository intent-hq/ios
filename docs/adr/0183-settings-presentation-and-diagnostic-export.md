# ADR-0183: Settings presentation and diagnostic export

- Status: Accepted
- Recorded: 2026-11-20 (moved from code comments; the decisions are older)
- Applies to: `SettingsView` (`Intent/Views/Settings/SettingsView.swift`), `SettingsStyle` (`Intent/Views/Settings/SettingsStyle.swift`), `LogOffConfirmationSheet` (`Intent/Views/Settings/LogOffConfirmationSheet.swift`), `AcknowledgementsView` (`Intent/Views/Settings/AcknowledgementsView.swift`), `DiagnosticExportView` (`Intent/Views/Settings/DiagnosticExportView.swift`), `DiagnosticShareSheet` (`Intent/Views/Settings/DiagnosticShareSheet.swift`)

## Decisions

### 1. Settings does not change the app-wide theme

Applies to: `SettingsStyle`, `SettingsView`

The Settings surface deliberately does not change the app-wide theme. It keeps
the real system status bar and its light and dark contrast. It does not draw the
status bar or force the rest of Settings into dark mode. The presenting
controller sets `modalPresentationCapturesStatusBarAppearance`, because a
non-fullscreen presentation otherwise keeps the presenting screen's status-bar
style.

### 2. The log-off sheet height is an estimate

Applies to: `LogOffConfirmationSheet`

`initialHeight` (400) is only an estimate. `ConnectionSheet` replaces it with
measured, scrollable content.

### 3. Licenses are reproduced in full

Applies to: `AcknowledgementsView`

The open-source acknowledgements are shown from Settings. Each entry reproduces
the dependency's license text in full, as its terms require for binary
distribution.

### 4. Diagnostic export works offline

Applies to: `DiagnosticExportView`

The view has no backend or session environment dependency, so every entry point
works offline.

### 6. The export list keeps native list button styles

Applies to: `DiagnosticExportView`

The diagnostic export list keeps the native list button styles. Only navigation
uses Intent button chrome.

### 5. The share sheet callback keeps the lease and logs nothing foreign

Applies to: `DiagnosticShareSheet.makeUIViewController(context:)`

UIKit retains `completionWithItemsHandler` (and the lease it captures) for the
consumer's lifetime, even if SwiftUI removes the presenting view. No foreign
error, returned item, activity identifier, or URL goes into logs.

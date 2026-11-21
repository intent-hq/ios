# ADR-0219: UI test fixtures and evidence

**Status:** Accepted (recorded 2026-11-20 from code comments)

## Context

UI tests run on shared CI simulators without a daemon. They must not touch live data or user accounts, and some suites are inputs to tools outside XCTest.

## Decision

1. **Demo data only.**
   1. UI tests use `--demo-data` and demo RPC seams. They never use a live backend, real credentials, a QR scan, or a system share destination.
   2. Tests use the real navigation, store and connection paths. They never add a test-only production hook or a screenshot-only screen.
   3. Tests that only edit a draft never tap Create. Demo `workspace.create` returns no workspace, so a create test exercises the real failure UI.
2. **No app imports.** The UI test target cannot import the app module. A test mirrors an app constant by value (for example `Constants.Conversation.Composer.maximumImageSelectionCount`) and matches fixture text.
3. **Launch arguments.** An argument-domain default (for example `-appThemePreference`) masks later writes. Remove it from the launch arguments before a test checks a stored value.
4. **Persisted state.** A test that changes a persisted choice restores it in teardown, so later tests start from the default.
5. **Connection loss.** Loss and recovery come from the demo connection publisher and trigger files. Tests never toggle host networking or use fixed presentation delays.
6. **Startup fixture.** `StartupWebSocketFixture` is a pinned TLS peer in the UI runner, separate from the app. Requests go through real host racing, hello admission, polling and reconnect.
7. **Failure evidence.** `FixtureCaptureLifecycleUITests` fails on purpose. `scripts/verify_fixture_capture_lifecycle.py` requires its assertion to stay failed.
8. **App Store screenshots.** Run `AppStoreScreenshotTests` only through `bundle exec fastlane screenshots`. That lane erases the simulators and seeds SpringBoard preferences first. The pairing screenshot launches without demo arguments.
9. **SnapshotHelper.** `SnapshotHelper.swift` is vendored from fastlane. Keep its `// SnapshotHelperVersion [x.y]` line: fastlane snapshot reads it to detect an outdated helper. Update the version with the file.
10. **Opt-in suites.** `HomeActionMenuUITests` checks the vertical bar only with `INTENT_UITEST_VERTICAL_BAR=1`. `WorkspaceWindowControlsUITests` needs an iPad simulator with native Windowed Apps enabled, not a size-class override.

## Consequences

- A new UI test that needs data adds a demo fixture or demo launch argument, not a live call.

## Code

- `CreateWorkspaceSelectionUITests`, `PairingDesignUITests`, `DiagnosticExportUITests`, `ShareWorkspaceUITests`, `InviteJoinUITests`
- `WorkspaceComposerUITests`: `imageLimit`
- `HomeActionMenuUITests`, `WorkspaceListMenuUITests`
- `ConnectionLossUITests`, `ConnectionLossUITestFixture`
- `StartupWebSocketFixture`
- `FixtureCaptureLifecycleUITests`
- `AppStoreScreenshotTests`, `SnapshotHelper.swift`

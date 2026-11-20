# 0107. App bundle and build configuration contracts

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

Some app behaviour comes from files that the compiler does not check: the Info.plist files, bundled fonts, the privacy manifest and build settings. A drift in these files only shows on a device or in App Review. Unit tests pin them instead.

## Decision

1. **visionOS Info.plist is a full copy.** `Info-visionOS.plist` is a full copy of `Intent/Info.plist`, chosen by the SDK-conditioned `INFOPLIST_FILE` build setting, plus exactly two keys: `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`. These keys must not appear on iOS.
   1. The copy is on purpose. The per-SDK `INFOPLIST_KEY_` route leaves empty usage keys in the built iOS plist.
   2. `InfoPlistSyncTests` checks that every iOS key is mirrored verbatim. It reads both plists from the copies packaged into the test bundle, not from the checkout.
   3. Multi-scene support is a shared key (backend-pinned windows through `WindowGroup(for: BackendID.self)` on visionOS and iPad). The test pins its value, so a regression fails on purpose and not as a missing-key sync error.
2. **Read the built plist.** Orientation checks read the built `Info.plist` file, not `Bundle`'s dictionary for the current device. An iPad runtime can leave the iPhone-qualified entry out of that view.
3. **Fonts.** Inter is registered only through `UIAppFonts` at launch. Tests never register fonts by hand, so they exercise the launch path. Synchronized groups copy the TTF files to the app bundle root, and the PostScript names come from the static TTF name tables (name ID 6).
4. **Privacy manifest (ios#381).** `Intent/PrivacyInfo.xcprivacy` follows the required-reason APIs that production code calls. Reading system boot time (`ProcessInfo.systemUptime` or `mach_absolute_time()`) requires `NSPrivacyAccessedAPICategorySystemBootTime` with an approved reason; the transcript scroll timing measures elapsed time between in-app events, which is reason `35F9.1`. A declaration with no remaining caller is stale and fails too. Only `Intent/` is scanned, because test code does not ship.
5. **Release smoke test (#468).** `ReleaseConfigurationTests` exists only in the Release test bundle, so a Debug bundle cannot satisfy the wrapper's Release smoke command. Debug-only helpers such as `connectDemo` do not exist in Release code.

## Consequences

- A new Info.plist key goes into both files in the same change.

## Code

- `Intent/Info.plist`, `Info-visionOS.plist`
- `InfoPlistSyncTests`, `InterFontTests`, `PrivacyManifestDriftTests`, `ReleaseConfigurationTests`
- `Intent/PrivacyInfo.xcprivacy`

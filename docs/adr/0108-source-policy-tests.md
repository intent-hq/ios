# 0108. Source policy tests

**Status:** Accepted (recorded 2026-11-20 from test comments)

## Context

Some repository rules cannot be left to SwiftLint alone, because a lint rule can be suppressed in the file it checks. Unit tests scan the Swift sources instead. The sources come from the copies packaged into the test bundle (`TestSourceInputs`), never from the checkout through `#filePath` (ios#320).

## Decision

1. **Independent of lint.** A policy test enforces its rule even when the matching SwiftLint rule is suppressed. `LayoutPolicyTests` bans `GeometryReader` and any suppression of `geometry_reader_usage`.
2. **Self-scan safe.** A policy test scans its own source too. Banned tokens in its fixtures and patterns are split (`"Geometry" + "Reader"`), so the test passes its own scan. Do not join them.
3. **Thread-hopping ObjC callbacks.** The app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Some SDK block parameters import as plain non-Sendable function types, so a closure literal passed to them can be inferred main-actor isolated (SE-0434 allows this, and no compiler setting reports it). The process then aborts in `_dispatch_assert_queue_fail` when the framework calls the closure off the main thread, which a simulator does not reliably reproduce (fixed instance: 09c22b6, `SpeechDictationController`).
   1. `ObjCCallbackIsolationTests` is the registry of known thread-hopping callback APIs. A call site passes only when its closure literal opens with `{ @Sendable`, or when the call is `await`-ed (async overloads hop isolation correctly). The `await` exemption counts only the matched call's own statement, after the last `;` before the match.
   2. Explicit `@Sendable` is required also in nonisolated helpers, so a moved callback cannot inherit the main actor.
   3. AVCapture delegate setters take delegate objects, not closures, so every use fails by design: audit the delegate's isolation, then teach the test the audited pattern.
   4. Add an API to the table when the app adopts another ObjC callback that runs off the main thread. Current entries and the queue they call on:

      | API | Calls on |
      | --- | --- |
      | `installTap(` (AVAudioNode) | realtime audio thread |
      | `recognitionTask(with` (SFSpeechRecognizer) | Speech-owned queue |
      | `SFSpeechRecognizer.requestAuthorization` | arbitrary queue |
      | `AVAudioApplication.requestRecordPermission` | arbitrary queue |
      | `.setSampleBufferDelegate(` (AVCaptureVideoDataOutput) | delegate queue |
      | `.setMetadataObjectsDelegate(` (AVCaptureMetadataOutput) | delegate queue |
      | `.addObserver(forName` (NotificationCenter) | posting thread |
      | `.pathUpdateHandler =` (Network) | connection or monitor queue |
      | `.viabilityUpdateHandler =` (NWConnection) | connection queue |
      | `.stateUpdateHandler =` (NWConnection, NWListener) | configured queue |
      | `sec_protocol_options_set_verify_block(` (Network TLS) | supplied verification queue |
      | `.completionWithItemsHandler =` (UIActivityViewController) | defensive isolation boundary |

4. **Platform guards.** `#if os(visionOS)` and `#if canImport(TailcatKit)` may appear only in the files that `PlatformGuardAllowlistTests` lists. Adding or removing a guard anywhere else is a deliberate change to that list. The patterns allow whitespace inside the parentheses, so a spaced spelling cannot bypass the scan, and the test writes its own spellings so that its packaged copy does not match itself.
5. **Negative cases.** Each scanning test also runs on a small fixture tree and must report exactly the fixture's matches. A pass then proves the tree's contents, not an empty or unreadable scan.
6. **Code only.** The privacy-manifest scan blanks comments and string literals before it matches, so prose cannot stand in for a call. A literal that interpolates an expression is kept, because the expression is code.

## Consequences

- A policy test that reads a token from a comment breaks when the comment is deleted; the token must live in code or a string.

## Code

- `LayoutPolicyTests`: `reader`, `suppression`
- `ObjCCallbackIsolationTests`: `threadHoppingCallbackAPIs`, `callSiteIsSafe`
- `PlatformGuardAllowlistTests`, `PrivacyManifestDriftTests`
- `TestSourceInputs`

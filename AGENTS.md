# Agents — ios

- Start with [README.md](README.md) for setup, architecture, dependencies, and command details; keep both documents aligned when those contracts change.
- This repo is `packages/ios` in the monorepo. Follow its [commit and PR workflow](https://github.com/intent-hq/intent/blob/main/AGENTS.md#commit--pr-workflow); routine monorepo pin bumps are automated.
- Sources of truth: [project settings](Intent.xcodeproj/project.pbxproj), [Swift packages](Intent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved), [Go module](TailcatKit/go.mod), and [CI](.github/workflows/ci.yml).

## SwiftUI layout

- `GeometryReader` is banned in `Intent/`, `IntentTests/`, and `IntentUITests/`; never suppress `geometry_reader_usage`. [LayoutPolicyTests](IntentTests/LayoutPolicyTests.swift) also enforces this.
- Use `onGeometryChange`, `containerRelativeFrame`, `Shape.path(in:)`, or a custom `Layout`.

## Platform guards

- Keep visionOS as a destination of the single `Intent` target; every visionOS branch must preserve existing iOS behavior.
- Register files that deliberately use `#if os(visionOS)` or `#if canImport(TailcatKit)` in the allowlist in [PlatformGuardAllowlistTests](IntentTests/PlatformGuardAllowlistTests.swift).
- Preserve both packaged source resources: `TestSourceInputs/` via [TestSourceInputs](IntentTests/TestSourceInputs.swift) and generated `SourceInputs/` via [TestBundleInputs](IntentTests/TestBundleInputs.swift).
- Source-backed tests must read bundle resources, never the checkout through `#filePath` (ios#320); preserve the Copy Test Source Inputs phase and [generator inputs](scripts/test-source-inputs.xcfilelist).

## Building and testing

- Run every command-line Xcode build/test through `scripts/xcodebuild.sh`; direct invocations and `-sdk` overrides are forbidden.

| Task | Command |
| --- | --- |
| iOS / visionOS build | `scripts/xcodebuild.sh build-ios` / `scripts/xcodebuild.sh build-visionos` |
| Physical iOS build | `DEVICE_UDID=<device-id> scripts/xcodebuild.sh build-ios-device` (project signing; build only) |
| Full pre-PR test gate | `scripts/xcodebuild.sh test-ios` |
| Pre-PR lint gate | `scripts/swiftlint.sh` |
| Focused unit iteration | `ONLY_TESTING='IntentTests/DemoFixturesTests' scripts/xcodebuild.sh test-ios-unit` |
| Split mixed/unit run | `scripts/xcodebuild.sh build-for-testing`, then `scripts/xcodebuild.sh test-without-building` or `scripts/xcodebuild.sh test-without-building-unit` |
| Split UI-only run | `scripts/xcodebuild.sh build-for-testing-ui`, then `scripts/xcodebuild.sh test-without-building-ui` |
| Release runtime check | `BUILD_CONFIGURATION=Release ONLY_TESTING='IntentTests/ReleaseConfigurationTests' scripts/xcodebuild.sh test-ios-unit` |

- Build before test-without-building runs and rebuild after source/configuration changes; keep `SIM_UDID`, `DERIVED_DATA_DIR`, and `BUILD_CONFIGURATION` consistent across each pair.
- Use separate derived-data directories and simulators for concurrent runs; the wrapper serializes tests on a shared simulator.
- `ONLY_TESTING` accepts whitespace-separated runnable `Target[/Suite[/test]]` identifiers; filenames are not selectors. Inspect executed/skipped counts before claiming coverage; all-skipped selections can pass.
- For Release split runs, set `BUILD_CONFIGURATION=Release` on both commands; Debug results and Debug-only fixtures are not Release coverage.
- After adding, removing, splitting, or moving Swift files, run `scripts/update-source-lists.sh`; it regenerates both Xcode input lists (test sources and SwiftLint) from the working tree.
- Linux agents cannot compile Swift, so a Mac helper agent runs iOS tests. Give it one command: `scripts/run_commit_tests.sh <full-sha> 'IntentTests/<Suite>' ...` (single-quote each selector). It tests that commit in a clean temporary checkout through the wrapper and writes `~/Library/Caches/intent-ios-test-run/summary.md`: verdict, per-suite counts, failing tests, and the rerun command. Run it in the foreground; a restarted agent reads the summary instead of asking for the steps again.
- Read the [wrapper header](scripts/xcodebuild.sh) for locks, crash retries, and exit codes; use [prerequisites](README.md#clean-checkout-prerequisites), [wrapper commands](README.md#xcode-wrapper-commands), and [SwiftLint setup](README.md#strict-lint-on-linux) for toolchain details.

## CI and UI evidence

- Preserve the [CI contracts](README.md#ci-and-review-evidence) and [runner allocation](README.md#github-actions-runners), including independent lane resources, `fail-fast: false`, and an aggregate check requiring every lane to succeed.
- Keep [smoke selectors](scripts/ui-smoke-tests.txt) small, update renamed tests, and maintain valid shard annotations; selection must reject duplicates and empty shards before native tests run.
- Both workspace creation entry tests in [WorkspaceListMenuUITests](IntentUITests/WorkspaceListMenuUITests.swift) must exercise light and dark appearances on every run.
- Transcript quarantine: [ConversationTranscriptFullGateUITests.swift](IntentUITests/ConversationTranscriptFullGateUITests.swift) extends `ConversationTranscriptScrollUITests`; select `ONLY_TESTING='IntentUITests/ConversationTranscriptScrollUITests'` with `TEST_RUNNER_INTENT_UITEST_FULL_GATE_REPRO=1` on a local wrapper run.
- Full runs still honor skips and quarantines; keep `AppStoreScreenshotTests` excluded from both schemes and follow the separate [Mermaid quarantine](README.md#mermaid-ui-quarantine) (ios#735 is closed; lifting the remaining guard is tracked in ios#940).
- Preserve full-suite inventory partitioning and cross-lane coverage verification; only the first iPhone shard owns the [screenshot-retention contract](README.md#ui-evidence-artifacts).
- Extend the explicit allowlist in [export_ui_evidence.py](scripts/export_ui_evidence.py); review the exported PNGs before claiming visual coverage and keep screenshots outside git.
- Keep evidence exports separate per lane, record runner/toolchain details for timings, and retain failure/cancellation results and logs with `pipefail`.

## Tooling regression checks

Run the matching checks after changing tooling:

| Changed area | Checks |
| --- | --- |
| Xcode wrapper | `scripts/test_xcodebuild.sh` |
| Mac commit test runner | `scripts/test_run_commit_tests.sh` |
| Source-input generator | `scripts/test-generate-test-inputs.sh` |
| Source-list updater / shared enumeration (`scripts/source-lists.sh`) | `scripts/test-update-source-lists.sh`; `scripts/test-check-swiftlint-inputs.sh`; `scripts/test-generate-test-inputs.sh` |
| CI / test selection | `python3 scripts/test_ci_simulator.py`; `python3 scripts/test_ui_smoke_tests.py`; `python3 scripts/test_ui_full_tests.py` |
| Runner / capture selection | `python3 scripts/test_select_macos_runner.py`; `python3 scripts/test_select_fixture_capture_repetitions.py` |
| Evidence exporter | `python3 scripts/test_export_ui_evidence.py` (on macOS, prefix with `TMPDIR=/private/tmp`) |
| SwiftLint wrapper / input checker | `scripts/test-swiftlint.sh`; `scripts/test-check-swiftlint-inputs.sh`; Linux setup/runtime checks are in the [lint guide](README.md#strict-lint-on-linux) |
| Xcode Cloud preparation | `scripts/test-ci-post-clone.sh` |
| UI attachment lifecycle check | `python3 scripts/check_ui_attachment_lifecycle.py`; `python3 scripts/test_check_ui_attachment_lifecycle.py` |
| Capture-lifecycle verifier | `python3 scripts/test_fixture_capture_lifecycle.py` |
| Protocol fixture versions | `python3 scripts/test_protocol_fixture_version.py`; `python3 scripts/protocol_fixture_version.py lint` |
| Deferred row-provider boundary | `scripts/test-row-provider-isolation.sh` (macOS) |

## Transport and bundled content

- Require trusted certificate fingerprints for WSS/TLS, including Tailcat routes; never restore legacy plaintext fallback. [WebSocketConnectionSecurity.swift](Intent/Services/WebSocketConnectionSecurity.swift) limits the override to Debug loopback tests; Release must reject missing pins.
- Regenerate bundled diagrams through the [Pele vendoring workflow](README.md#offline-mermaid-rendering-with-pele); preserve its renderer/security contract and review both appearances. Keep the lockfile, bundle, provenance, and licenses consistent.
- Regenerate file highlighting through the [Pierre vendoring workflow](README.md#offline-file-syntax-highlighting-with-pierre); keep the bundle, lockfile, provenance, and notices together, preserve plain-text fallback, and review both appearances.
- Browser stale-request tests must gate font preparation while Pele rendering stays synchronous; native probes must remain bounded without WebKit callbacks. Preserve missing/late-callback and cancellation coverage in [MermaidJavaScriptProbeTests](IntentTests/MermaidWebViewTests.swift).

## Releases

- Set versions in `Intent.xcodeproj/project.pbxproj`: `MARKETING_VERSION` → `CFBundleShortVersionString`, `CURRENT_PROJECT_VERSION` → `CFBundleVersion`; keep Debug/Release consistent for all three targets and iOS/visionOS. Leave version keys out of both app plists.
- Before choosing numbers, check repository settings and App Store Connect/TestFlight uploads, including in-flight builds; ask if the baseline or intended release is unclear.
- Every new release/upload needs a marketing-version increase (patch for ordinary fixes unless specified) and a fresh build number above all known prior uploads.
- Retain the marketing version only for an explicitly requested rebuild of that same unreleased release; still use a fresh build number.
- Verify CI/Xcode Cloud's effective build number; automatic build numbering does not increase the marketing version.
- Before upload, inspect both version keys in the actual archive/export; rebuild mismatches, never relabel. After processing, confirm the displayed pair and record it in the release handoff.
- Upload, submission, and release remain human-controlled; `ci_scripts/ci_post_clone.sh` only prepares dependencies.

## Where to look

| Area | Entry points |
| --- | --- |
| Thread-hopping ObjC callbacks | [ObjCCallbackIsolationTests](IntentTests/ObjCCallbackIsolationTests.swift): follow its registry and explicit `@Sendable` guard. |
| Transcript / Go to End | [ConversationTranscriptScrollUITests](IntentUITests/ConversationTranscriptScrollUITests.swift) and companion files; use `--demo-data` and inspect runtime skips. |
| Workspace Changes / diffs | [WorkspaceChangesStore](Intent/Services/WorkspaceChangesStore.swift), [WorkspaceDiffLoader](Intent/Services/WorkspaceDiffLoader.swift), [WorkspaceChangesUITests](IntentUITests/WorkspaceChangesUITests.swift). |
| Terminal | [MobileTerminalStore](Intent/Services/MobileTerminalStore.swift), [MobileTerminalConnection](Intent/Services/MobileTerminalConnection.swift), [MobileTerminalUITests](IntentUITests/MobileTerminalUITests.swift). |

## Issues and pull requests

- File discovered bugs/limitations in [intent-hq/ios](https://github.com/intent-hq/ios/issues), never the monorepo tracker or Markdown files; apply `component:ios` and `agent-filed`.
- Deduplicate with `gh issue list --repo intent-hq/ios --search "<keywords>" --state all`; comment on/link existing issues and reference their numbers in related commits/PRs.
- Use conventional commits and PR titles; merging requires explicit human permission under the linked monorepo workflow.
- UI PRs require screenshots in the description. Use **GitHub CLI 2.99.0+** for [`--attach` support](https://github.blog/changelog/2026-09-01-github-cli-media-in-issues-pull-requests-and-comments/); check `gh --version` before uploading.
- Example: `gh pr create --repo intent-hq/ios --title "fix: describe the UI change" --body-file /tmp/intent-pr.md --attach /tmp/intent-screenshot.png`. Never commit screenshot files.

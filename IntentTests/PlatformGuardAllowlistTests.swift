import Foundation
import Testing

/// Enforces the platform-guard allowlist from AGENTS.md § Platform guards:
/// the visionOS `#if os(...)` guard and the TailcatKit `#if canImport(...)`
/// guard may appear only in the files listed below. Adding a guard to any
/// other file (or removing one from a listed file) must be a deliberate act —
/// update the allowlist in IntentTests/PlatformGuardAllowlistTests.swift
/// alongside the change. (The guard patterns are regexes tolerating
/// whitespace around the parentheses, so a space-separated guard spelling
/// cannot bypass the scan; the patterns' escaped spelling also keeps this
/// file from matching its own scan.)
struct PlatformGuardAllowlistTests {
    private static let visionOSGuard = #"os\s*\(\s*visionOS\s*\)"#
    private static let tailcatKitGuard = #"canImport\s*\(\s*TailcatKit\s*\)"#

    private static let visionOSAllowlist: Set<String> = [
        "Intent/App/IntentApp.swift",
        "Intent/App/RootView.swift",
        "Intent/DesignSystem/Layout.swift",
        "Intent/DesignSystem/VisionHitTarget.swift",
        "Intent/Services/SpeechDictationController.swift",
        "Intent/Utils/HapticManager.swift",
        "Intent/Utils/NotificationManager.swift",
        "Intent/Views/Components/NavigationTitleSubtitleView.swift",
        "Intent/Views/Components/WindowFeedbackSoundEmitter.swift",
        "Intent/Views/Conversation/Composer/MessageInputView.swift",
        "Intent/Views/Conversation/Composer/SubmittableTextView.swift",
        "Intent/Views/Conversation/Transcript/ConversationColumnView.swift",
        "Intent/Views/Conversation/Transcript/ConversationTranscriptView.swift",
        "Intent/Views/Onboarding/ManualTokenEntryView.swift",
        "Intent/Views/Onboarding/PairingView.swift",
        "Intent/Views/Onboarding/QRScannerView.swift",
        "Intent/Views/Workspaces/WorkspaceAttentionCue.swift",
        "Intent/Views/Workspaces/WorkspaceDetailView.swift",
        "Intent/Views/Workspaces/WorkspaceListSidebar.swift",
        "Intent/Views/Workspaces/WorkspaceListView.swift",
        "IntentTests/PairingOptionTests.swift"
    ]

    private static let tailcatKitAllowlist: Set<String> = [
        "Intent/Services/ConnectionManager.swift",
        "Intent/Services/TailcatTunnel.swift",
        "IntentTests/TailcatKitSmokeTests.swift"
    ]

    /// Repo-relative paths of .swift files under Intent/ and IntentTests/
    /// whose contents match the regex `pattern`.
    private func filesContaining(_ pattern: String) throws -> Set<String> {
        var matches: Set<String> = []
        let inputs = try TestBundleInputs.current()
        for directory in ["Intent", "IntentTests"] {
            let files = try inputs.swiftFiles(under: directory)
            try #require(!files.isEmpty, "scan root \(directory)/ contains no Swift inputs")
            for file in files {
                let url = file.url
                let contents = try String(contentsOf: url, encoding: .utf8)
                guard contents.range(of: pattern, options: .regularExpression) != nil
                else { continue }
                matches.insert(file.path)
            }
        }
        return matches
    }

    private func assertMatchesAllowlist(
        pattern: String,
        allowlist: Set<String>
    ) throws {
        let actual = try filesContaining(pattern)
        let added = actual.subtracting(allowlist).sorted()
        let removed = allowlist.subtracting(actual).sorted()
        #expect(
            added.isEmpty && removed.isEmpty,
            """
            \(pattern) guard usage diverged from the allowlist.
            Files newly containing the guard (remove the guard or extend the \
            allowlist): \(added)
            Allowlisted files no longer containing the guard (stale entries): \
            \(removed)
            Deliberate changes: update the allowlist in \
            IntentTests/PlatformGuardAllowlistTests.swift.
            """
        )
    }

    @Test func visionOSGuardsMatchAllowlist() throws {
        try assertMatchesAllowlist(
            pattern: Self.visionOSGuard,
            allowlist: Self.visionOSAllowlist
        )
    }

    @Test func tailcatKitGuardsMatchAllowlist() throws {
        try assertMatchesAllowlist(
            pattern: Self.tailcatKitGuard,
            allowlist: Self.tailcatKitAllowlist
        )
    }
}

import Foundation
import Testing

/// Enforces the platform-guard allowlist from AGENTS.md § Platform guards:
/// the visionOS `#if os(...)` guard and the TailcatKit `#if canImport(...)`
/// guard may appear only in the files listed below. Adding a guard to any
/// other file (or removing one from a listed file) must be a deliberate act —
/// update the allowlist in IntentTests/PlatformGuardAllowlistTests.swift
/// alongside the change. (The guard patterns are split below so this file
/// does not match its own scan.)
struct PlatformGuardAllowlistTests {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // IntentTests/
        .deletingLastPathComponent()  // repo root

    // Split so this file does not match its own scan patterns.
    private static let visionOSGuard = "os(" + "visionOS)"
    private static let tailcatKitGuard = "canImport(" + "TailcatKit)"

    private static let visionOSAllowlist: Set<String> = [
        "Intent/App/IntentApp.swift",
        "Intent/DesignSystem/Layout.swift",
        "Intent/DesignSystem/VisionHitTarget.swift",
        "Intent/Services/SpeechDictationController.swift",
        "Intent/Utils/HapticManager.swift",
        "Intent/Views/Components/NavigationTitleSubtitleView.swift",
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
        "IntentTests/PairingOptionTests.swift",
    ]

    private static let tailcatKitAllowlist: Set<String> = [
        "Intent/Services/ConnectionManager.swift",
        "Intent/Services/TailcatTunnel.swift",
        "IntentTests/TailcatKitSmokeTests.swift",
    ]

    /// Repo-relative paths of .swift files under Intent/ and IntentTests/
    /// whose contents contain `pattern`.
    private func filesContaining(_ pattern: String) throws -> Set<String> {
        var matches: Set<String> = []
        let rootPrefix = Self.repoRoot.standardizedFileURL.path + "/"
        for directory in ["Intent", "IntentTests"] {
            let root = Self.repoRoot.appendingPathComponent(directory)
            var isDirectory: ObjCBool = false
            try #require(
                FileManager.default.fileExists(
                    atPath: root.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue,
                "scan root \(directory)/ is missing or not a directory at \(root.path)"
            )
            let enumerator = try #require(
                FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey]
                ),
                "failed to enumerate \(directory)/"
            )
            for case let url as URL in enumerator {
                guard url.pathExtension == "swift" else { continue }
                let contents = try String(contentsOf: url, encoding: .utf8)
                guard contents.contains(pattern) else { continue }
                let absolute = url.standardizedFileURL.path
                try #require(
                    absolute.hasPrefix(rootPrefix),
                    "scanned file \(absolute) is not under repo root \(rootPrefix)"
                )
                matches.insert(String(absolute.dropFirst(rootPrefix.count)))
            }
        }
        return matches
    }

    private func assertMatchesAllowlist(
        pattern: String, allowlist: Set<String>
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
            pattern: Self.visionOSGuard, allowlist: Self.visionOSAllowlist)
    }

    @Test func tailcatKitGuardsMatchAllowlist() throws {
        try assertMatchesAllowlist(
            pattern: Self.tailcatKitGuard, allowlist: Self.tailcatKitAllowlist)
    }
}

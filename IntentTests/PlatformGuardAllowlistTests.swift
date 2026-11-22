import Foundation
import Testing

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
        "Intent/Views/Components/AssistantLaunchButton.swift",
        "Intent/Views/Components/NavigationTitleSubtitleView.swift",
        "Intent/Views/Components/ToastBackground.swift",
        "Intent/Views/Components/WindowFeedbackSoundEmitter.swift",
        "Intent/Views/Connection/ConnectionSheet.swift",
        "Intent/Views/Conversation/Composer/FloatingComposerOrnament.swift",
        "Intent/Views/Conversation/Composer/MessageInputView.swift",
        "Intent/Views/Conversation/Composer/SubmittableTextView.swift",
        "Intent/Views/Conversation/Transcript/ConversationColumnView.swift",
        "Intent/Views/Conversation/Transcript/ConversationTranscriptView+Presentation.swift",
        "Intent/Views/Onboarding/ManualTokenEntryView.swift",
        "Intent/Views/Onboarding/PairingView.swift",
        "Intent/Views/Onboarding/QRScannerView.swift",
        "Intent/Views/Workspaces/CreateWorkspaceSelectionPage.swift",
        "Intent/Views/Workspaces/CreateWorkspaceSpecialistStepView.swift",
        "Intent/Views/Workspaces/WorkspaceActionMenuDepth.swift",
        "Intent/Views/Workspaces/WorkspaceAttentionCue.swift",
        "Intent/Views/Workspaces/WorkspaceDetailPresentations.swift",
        "Intent/Views/Workspaces/WorkspaceDetailSupport.swift",
        "Intent/Views/Workspaces/WorkspaceDetailView+PageChrome.swift",
        "Intent/Views/Workspaces/WorkspaceListSidebar.swift",
        "Intent/Views/Workspaces/WorkspaceListView.swift",
        "IntentTests/PairingOptionTests.swift"
    ]

    private static let tailcatKitAllowlist: Set<String> = [
        "Intent/Services/ConnectionManager.swift",
        "Intent/Services/TailcatTunnel.swift",
        "IntentTests/TailcatKitSmokeTests.swift",
        "IntentTests/TailcatTunnelSessionTests.swift"
    ]

    private func filesContaining(
        _ pattern: String, under repoRoot: URL = TestSourceInputs.root
    ) throws -> Set<String> {
        var matches: Set<String> = []
        let rootPrefix = repoRoot.standardizedFileURL.path + "/"
        for directory in ["Intent", "IntentTests"] {
            let root = repoRoot.appendingPathComponent(directory)
            var isDirectory: ObjCBool = false
            try #require(
                FileManager.default.fileExists(
                    atPath: root.path,
                    isDirectory: &isDirectory
                )
                    && isDirectory.boolValue,
                """
                scan root \(directory)/ is missing or not a directory at \
                \(root.path); check the IntentTests target's "Copy Test \
                Source Inputs" phase in Intent.xcodeproj.
                """
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
                guard contents.range(of: pattern, options: .regularExpression) != nil
                else { continue }
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

    @Test func scanReportsGuardedFilesOnly() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlatformGuardScan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let visionOS = "#if os(" + "visionOS)\n#endif\n"
        let spacedVisionOS = "#if os( " + "visionOS )\n#endif\n"
        let tailcatKit = "#if canImport(" + "TailcatKit)\n#endif\n"
        let files = [
            "Intent/Nested/Guarded.swift": visionOS,
            "Intent/Spaced.swift": spacedVisionOS,
            "Intent/Clean.swift": "#if os(iOS)\n#endif\n",
            "Intent/NotSwift.txt": visionOS,
            "IntentTests/TailcatGuarded.swift": tailcatKit
        ]
        for (path, contents) in files {
            let url = fixture.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        #expect(
            try filesContaining(Self.visionOSGuard, under: fixture)
                == ["Intent/Nested/Guarded.swift", "Intent/Spaced.swift"]
        )
        #expect(
            try filesContaining(Self.tailcatKitGuard, under: fixture)
                == ["IntentTests/TailcatGuarded.swift"]
        )
    }
}

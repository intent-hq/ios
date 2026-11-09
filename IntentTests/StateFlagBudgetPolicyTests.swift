import Foundation
import Testing

/// Ratchets the stored Bool flags and optional `Task` handles per app type.
/// Several of them moving together usually form an implicit state machine
/// that belongs in an enum (see `CoalescedRead`, `ConversationTranscriptScrollState.EntryScroll`).
/// Line-based on purpose: members sit at four spaces under a column-0 type.
struct StateFlagBudgetPolicyTests {
    /// Unlisted types may hold this many flags.
    static let allowance = 4

    /// Types already above the allowance. Counts may only go down; lower the
    /// entry (or delete it at the allowance) when a type sheds flags.
    static let baseline: [String: Int] = [
        "Intent/App/AppCoordinator.swift#AppCoordinator": 7,
        "Intent/App/IPadNavigationState.swift#IPadNavigationState": 6,
        "Intent/App/RootView.swift#RootView": 12,
        "Intent/Demo/DemoFixturesDesign.swift#DemoDesignFixtures": 6,
        "Intent/Demo/DemoScriptMonitorFixtures.swift#DemoScriptMonitorFixtures": 5,
        "Intent/Presentation/ConversationModelSelection.swift#ConversationModelSelection": 5,
        "Intent/Presentation/ConversationTranscriptScrollState.swift#ConversationTranscriptScrollState": 14,
        "Intent/Services/ConnectionManager.swift#ConnectionManager": 8,
        "Intent/Services/ConversationLiveTranscript.swift#ConversationLiveTranscript": 11,
        "Intent/Services/ConversationStore.swift#ConversationStore": 7,
        "Intent/Services/CreationOptionsStore.swift#CreationOptionsStore": 8,
        "Intent/Services/GitHubRepoStore.swift#GitHubRepoStore": 9,
        "Intent/ViewModels/ConversationViewModel.swift#ConversationViewModel": 8,
        "Intent/Views/Conversation/Questions/QuestionWizardView.swift#QuestionWizardView": 7,
        "Intent/Views/Conversation/Transcript/ConversationColumnView.swift#ConversationColumnView": 6,
        "Intent/Views/Conversation/Transcript/ConversationView.swift#ConversationViewContent": 8,
        "Intent/Views/Conversation/Transcript/WorkspaceConversationHeader.swift#WorkspaceNavigationHeader": 7,
        "Intent/Views/Onboarding/ManualTokenEntryView.swift#ManualTokenEntryView": 5,
        "Intent/Views/Onboarding/QRScannerView.swift#QRScannerView": 5,
        "Intent/Views/Workspaces/SpecialistPickerView.swift#SpecialistPickerView": 5,
        "Intent/Views/Workspaces/WorkspaceDetailPresentation.swift#WorkspaceDetailPresentation": 5,
        "Intent/Views/Workspaces/WorkspaceDetailSupport.swift#WorkspaceDetailHeading": 5,
        "Intent/Views/Workspaces/WorkspaceFileDiffView.swift#WorkspaceFileDiffView": 6,
        "Intent/Views/Workspaces/WorkspaceListView.swift#WorkspaceListView": 8,
        "Intent/Views/Workspaces/WorkspaceSwipeRow.swift#WorkspaceSwipeRow": 5
    ]

    private static let attributes = #"(?:@\w+(?:\([^)]*\))?\s+)*"#
    private static let typeDeclaration = regex(
        "^" + attributes + #"(?:(?:public|internal|private|fileprivate|final|nonisolated|open|indirect)\s+)*(?:class|struct|actor|enum)\s+([A-Za-z_]\w*)"#
    )
    private static let otherDeclaration = regex(
        "^" + attributes + #"(?:(?:public|internal|private|fileprivate|nonisolated)\s+)*(?:extension|func|let|var|protocol|typealias)\b"#
    )
    private static let member = regex(
        "^    " + attributes + #"(?:(?:private|fileprivate|internal|public)(?:\(set\))?\s+)*var\s+[A-Za-z_]\w*\s*(.*)$"#
    )
    private static let boolFlag = regex(#"^(?::\s*Bool\s*)?=\s*(?:true|false)\b|^:\s*Bool\s*(?://.*)?$"#)
    private static let taskHandle = regex(#"^:\s*Task<[^>]*>\?"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static func firstCapture(_ expression: NSRegularExpression, in line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression.firstMatch(in: line, range: range),
              let capture = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[capture])
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Flag counts keyed by `relative/path.swift#TypeName` for sources under `Intent/`.
    static func flagCounts(under root: URL = TestSourceInputs.root) throws -> [String: Int] {
        let sourceRoot = root.appendingPathComponent("Intent")
        let enumerator = try #require(
            FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: [.isRegularFileKey]),
            "Failed to enumerate Intent; check the Copy Test Source Inputs phase."
        )
        let rootPrefix = root.standardizedFileURL.path + "/"
        var counts: [String: Int] = [:]
        var scannedFiles = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scannedFiles += 1
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPrefix.count))
            var currentType: String?
            for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines) {
                if let name = firstCapture(typeDeclaration, in: line) {
                    currentType = name
                } else if matches(otherDeclaration, line) {
                    currentType = nil
                } else if let type = currentType, let rest = firstCapture(member, in: line),
                          matches(boolFlag, rest) || matches(taskHandle, rest) {
                    counts["\(relative)#\(type)", default: 0] += 1
                }
            }
        }
        try #require(scannedFiles > 0, "No Swift sources found under Intent; check the packaged inputs.")
        return counts
    }

    @Test func appTypesStayWithinTheirStateFlagBudget() throws {
        let counts = try Self.flagCounts()
        var problems: [String] = []
        for (key, count) in counts.sorted(by: { $0.key < $1.key }) {
            let budget = Self.baseline[key] ?? Self.allowance
            if count > budget {
                problems.append("\(key) has \(count) flags (budget \(budget)). Model the related flags as one enum or a shared type.")
            } else if let listed = Self.baseline[key], count < listed {
                problems.append("\(key) dropped to \(count) flags; lower its baseline from \(listed)\(count <= Self.allowance ? " or delete the entry" : "").")
            }
        }
        for key in Self.baseline.keys.sorted() where counts[key] == nil {
            problems.append("\(key) no longer exists; delete its baseline entry.")
        }
        #expect(problems.isEmpty, "State flag budget:\n\(problems.joined(separator: "\n"))")
    }

    @Test func scanCountsStoredFlagsAndTaskHandlesOnly() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("StateFlagBudgetScan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = """
        @MainActor
        @Observable final class Store {
            var isLoading = false
            @ObservationIgnored private(set) var hasLoaded: Bool = true
            var isStreaming = false {
                didSet { }
            }
            var needsRefresh: Bool
            var refreshTask: Task<Void, Never>?
            var isEmpty: Bool { true }
            let isFixed = false
            static var isShared = false
            var count = 0
            enum Phase {
                case idle
            }
            struct Nested {
                var isNested = false
            }
        }

        extension Store {
            var isDerived: Bool { false }
        }

        struct Other {
            @State private var showsSheet = false
        }
        """
        let url = fixture.appendingPathComponent("Intent/Nested/Store.swift")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: url, atomically: true, encoding: .utf8)
        try "var isGlobal = false".write(to: fixture.appendingPathComponent("Intent/Global.swift"), atomically: true, encoding: .utf8)

        #expect(try Self.flagCounts(under: fixture) == [
            "Intent/Nested/Store.swift#Store": 5,
            "Intent/Nested/Store.swift#Other": 1
        ])
    }
}

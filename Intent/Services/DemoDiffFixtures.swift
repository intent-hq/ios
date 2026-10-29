import Foundation

enum DemoDiffFixtures {
    struct File {
        let path: String
        let old: String
        let new: String
        let hunks: [WorkspaceDiffHunk]

        init(path: String, new: String, replacements: [(String, String)]) {
            self.path = path
            self.new = new
            old = replacements.reduce(new) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            // These bounded, literal fixtures are checked through the real loaders in tests.
            hunks = (try? WorkspaceDiffBuilder.hunks(old: old, new: new)) ?? []
        }

        var additions: Int { hunks.flatMap(\.lines).filter { $0.type == .addition }.count }
        var deletions: Int { hunks.flatMap(\.lines).filter { $0.type == .deletion }.count }

        var wireHunks: [[String: Any]] {
            hunks.map { hunk in
                [
                    "oldStart": hunk.oldStart, "oldLines": hunk.oldLines,
                    "newStart": hunk.newStart, "newLines": hunk.newLines,
                    "lines": hunk.lines.map { line -> [String: Any] in
                        var value: [String: Any] = ["type": line.type.rawValue, "content": line.content]
                        value["oldNumber"] = line.oldNumber
                        value["newNumber"] = line.newNumber
                        return value
                    }
                ]
            }
        }
    }

    static let files: [File] = [
        File(path: "Sources/Analytics.swift", new: DemoSourceFileFixtures.swift, replacements: [
            ("let enabled = true", "let enabled = false"),
            ("// Collect workspace activity in small batches.", "/* Collect workspace activity.\n   This collector is still experimental. */"),
            ("pending.removeAll(keepingCapacity: true)", "pending.removeAll()")
        ]),
        File(path: "Sources/report.py", new: DemoSourceFileFixtures.python, replacements: [
            ("BATCH_SIZE = 20", "BATCH_SIZE = 10"),
            ("return event.duration_ms > 250.0", "return event.duration_ms > 500.0")
        ]),
        File(path: "Sources/collector.go", new: DemoSourceFileFixtures.golang, replacements: [
            ("const BatchLimit = 20", "const BatchLimit = 10"),
            ("return len(c.pending) >= BatchLimit", "return len(c.pending) > 0")
        ]),
        File(path: "Config/analytics.json", new: DemoConfigurationFileFixtures.json, replacements: [
            ("\"schemaVersion\": 2", "\"schemaVersion\": 1"),
            ("\"retryLimit\": 5", "\"retryLimit\": 3")
        ]),
        File(path: "Config/analytics.yaml", new: DemoConfigurationFileFixtures.yaml, replacements: [
            ("version: 2", "version: 1"),
            ("limit: 5", "limit: 3")
        ]),
        File(path: "Web/collector.ts", new: DemoWebFileFixtures.typescript, replacements: [
            ("export const batchLimit = 20", "export const batchLimit = 10"),
            ("return this.pending.length >= batchLimit", "return this.pending.length > 0")
        ]),
        File(path: "Web/dashboard.css", new: DemoWebFileFixtures.css, replacements: [
            ("--accent: #336699", "--accent: #555555"),
            ("border-radius: 12px", "border-radius: 4px")
        ]),
        File(path: "Scripts/report.sh", new: DemoWebFileFixtures.shell, replacements: [
            ("batch_limit=20", "batch_limit=10"),
            ("describe_batch 2", "describe_batch 1")
        ]),
        File(path: "Tests/AnalyticsTests.swift", new: DemoSourceFileFixtures.swiftTests, replacements: [
            ("let staged = true", "let staged = false"),
            ("#expect(first.count == 1)", "#expect(first.isEmpty)")
        ]),
        File(path: "Sources/Analytics/Events.swift", new: DemoFilesFixtures.events, replacements: [
            ("let enabled = true", "let enabled = false"),
            ("return batch.count", "return events.count")
        ])
    ]
}

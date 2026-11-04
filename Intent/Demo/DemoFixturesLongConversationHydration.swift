#if DEBUG
import Foundation

extension DemoFixtures {
    // Fixture output intentionally models a long numbered source listing.
    // swiftlint:disable no_magic_numbers
    // swiftlint:disable:next large_tuple
    static let longConversationTruncatedToolCalls: [(id: String, file: String, symbol: String)] = [
        ("demo-long-slim-tool-1", "tests/payments/evidence/final_evidence_table.py", "render_final_evidence"),
        ("demo-long-slim-tool-2", "tests/payments/evidence/repro_loop_report.py", "summarize_repro_loop")
    ]

    static let truncatedOutputPreviewLength = 160

    enum LongConversationSlimToolRowLayout: String, CaseIterable {
        /// The tool blocks open the assistant's text message, matching a
        /// coordinator turn on the daemon.
        case leading
        /// The tool blocks occupy their own assistant message immediately
        /// before the related text message, making the row independently tappable.
        case standalone
    }

    static let longConversationSlimToolRowLayout = slimToolRowLayout(from: ProcessInfo.processInfo.arguments)
    static let slimToolRowLayoutArgumentPrefix = "--demo-long-slim-tool-rows="

    static func slimToolRowLayout(from arguments: [String]) -> LongConversationSlimToolRowLayout {
        arguments
            .filter { $0.hasPrefix(slimToolRowLayoutArgumentPrefix) }
            .compactMap { argument in
                LongConversationSlimToolRowLayout(
                    rawValue: String(argument.dropFirst(slimToolRowLayoutArgumentPrefix.count))
                )
            }
            .last ?? .leading
    }

    // Nil means the requested fixture block does not exist, not an empty result block.
    // swiftlint:disable discouraged_optional_collection
    /// Full result block for a slim-truncated fixture tool result.
    static func longConversationFullBlock(id blockId: String?) -> [String: Any]? {
        guard let call = longConversationTruncatedToolCalls.first(where: { "\($0.id)-result" == blockId }) else {
            return nil
        }
        return toolResultBlock(toolUseId: call.id, output: longConversationFullOutput(for: call))
    }
    // swiftlint:enable discouraged_optional_collection

    // swiftlint:disable large_tuple
    static func truncatedToolBlocks(
        _ call: (id: String, file: String, symbol: String)
    ) -> [[String: Any]] {
        let output = longConversationFullOutput(for: call)
        var result = toolResultBlock(
            toolUseId: call.id,
            output: String(output.prefix(truncatedOutputPreviewLength))
        )
        result["outputTruncated"] = true
        result["outputBytes"] = output.utf8.count
        return [
            toolUseBlock(id: call.id, name: "view", input: ["path": call.file]),
            result
        ]
    }
    // swiftlint:enable large_tuple

    // swiftlint:disable large_tuple
    /// A multi-screen numbered listing that expands the tool row after hydration.
    private static func longConversationFullOutput(
        for call: (id: String, file: String, symbol: String)
    ) -> String {
        var lines = [
            call.file,
            "   1 | \"\"\"Evidence rendering for the flake investigation.\"\"\"",
            "   2 | from dataclasses import dataclass",
            "   3 | from statistics import quantiles",
            "   4 | ",
            "   5 | ",
            "   6 | @dataclass(frozen=True)",
            "   7 | class RunSample:",
            "   8 |     workers: int",
            "   9 |     duration_seconds: float",
            "  10 |     failures: int",
            "  11 | ",
            "  12 | ",
            "  13 | def \(call.symbol)(samples: list[RunSample]) -> str:",
            "  14 |     rows = [\"| Run | Workers | Duration | Failures |\", \"|-----|---------|----------|----------|\"]"
        ]
        for run in 1 ... 40 {
            let line = 14 + run
            let index = run - 1
            lines.append(
                "  \(line) |     rows.append(f\"| \(run) | {samples[\(index)].workers} | "
                    + "{samples[\(index)].duration_seconds:.1f}s | {samples[\(index)].failures} |\")"
            )
        }
        lines += [
            "  55 |     p50, p90 = quantiles([s.duration_seconds for s in samples], n=10)[4], "
                + "quantiles([s.duration_seconds for s in samples], n=10)[8]",
            "  56 |     rows.append(f\"| p50 | — | {p50:.1f}s | — |\")",
            "  57 |     rows.append(f\"| p90 | — | {p90:.1f}s | — |\")",
            "  58 |     return \"\\n\".join(rows)"
        ]
        return lines.joined(separator: "\n")
    }
    // swiftlint:enable large_tuple
    // swiftlint:enable no_magic_numbers
}
#endif

import Foundation
import Testing

/// Test-only, bounded observations. Encoding and output happen after owned cleanup.
@MainActor
final class SyntheticBadgeHostTrace {
    struct Entry: Codable {
        let event: String
        let elapsed: TimeInterval
        let fields: [String: String]
        let state: [String: String]
    }

    struct Report: Codable {
        let id: String
        let context: String
        let startedAt: TimeInterval
        let startedUptime: TimeInterval
        let entries: [Entry]
        let omittedEntries: Int
    }

    static let capacity = 96
    let id = UUID().uuidString
    var captureState: (() -> [String: String])?
    private(set) var entries: [Entry] = []
    private(set) var omittedEntries = 0
    private let context: String
    private let startedAt = Date().timeIntervalSince1970
    private let startedUptime: TimeInterval
    private let clock: () -> TimeInterval

    init(context: String, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.context = context
        self.clock = clock
        startedUptime = clock()
    }

    func record(_ event: String, fields: [String: String] = [:]) {
        let elapsed = clock() - startedUptime
        if entries.count == Self.capacity {
            // Keep the initial wait/trigger evidence and the most recent cleanup boundary.
            entries.removeLast()
            omittedEntries += 1
        }
        entries.append(Entry(event: event, elapsed: elapsed, fields: fields, state: captureState?() ?? [:]))
    }

    func encodedReport() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(Report(
            id: id,
            context: context,
            startedAt: startedAt,
            startedUptime: startedUptime,
            entries: entries,
            omittedEntries: omittedEntries
        ))
    }

    func publish() {
        do {
            guard let report = String(data: try encodedReport(), encoding: .utf8) else {
                print("SYNTHETIC host trace \(id) was not UTF-8")
                return
            }
            print("SYNTHETIC host trace: \(report)")
            if Test.current != nil {
                Attachment.record(report, named: "synthetic-host-\(id).json")
            }
        } catch {
            // Diagnostic failure must not replace the render or teardown error.
            print("SYNTHETIC host trace \(id) encoding failed: \(error)")
        }
    }
}

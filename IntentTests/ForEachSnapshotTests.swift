@testable import Intent
import os
import SwiftUI
import Testing

@MainActor
struct ForEachSnapshotTests {
    @Test func largeSnapshotDefersProvidersAndRowBodies() {
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        let snapshots = (0..<2000).map { (id: $0, content: ProbeRow(index: $0, events: events)) }
        let rows = ForEach(snapshots: snapshots, id: \.id) { row in
            events.withLock { $0.append("provider-\(row.id)") }
            return row.content
        }

        #expect(rows.data.map(\.id) == Array(0..<2000))
        #expect(events.withLock { $0.isEmpty })
        let row = rows.content(snapshots[1000])
        #expect(row.index == 1000)
        #expect(events.withLock { $0 } == ["provider-1000"])
        _ = row.body
        #expect(events.withLock { $0 } == ["provider-1000", "body-1000"])
    }

    private struct ProbeRow: View {
        let index: Int
        let events: OSAllocatedUnfairLock<[String]>

        var body: some View {
            events.withLock { $0.append("body-\(index)") }
            return Text("Row \(index)")
        }
    }
}

import Foundation

struct InvitedImportOutcome {
    var addedIds: [UUID] = []
    var updatedIds: [UUID] = []
    var removedIds: [UUID] = []

    init() {}

    init(before: [StoredConnection], after read: ConnectionRegistryReadResult, suppressed: [UUID]) {
        // Known removals remain authoritative even when the final local read
        // fails. An unavailable registry supplies no evidence of other deletes.
        removedIds = suppressed
        guard let after = read.connections else { return }
        addedIds = after.filter { row in !before.contains { $0.id == row.id } }.map(\.id)
        updatedIds = after.filter { row in before.contains { $0.id == row.id && $0 != row } }.map(\.id)
        removedIds = Array(Set(suppressed + before.filter { row in !after.contains { $0.id == row.id } }.map(\.id)))
    }
}

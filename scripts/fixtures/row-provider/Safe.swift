import SwiftUI

@MainActor final class Store {
    var title = "Live title"
    func select() {}
}

struct SnapshotRow: View {
    let title: String
    let onSelect: @MainActor () -> Void

    var body: some View { Button(title, action: onSelect) }
}

@MainActor func safeRows(_ store: Store) -> some View {
    let rows = [(id: 1, content: SnapshotRow(title: store.title, onSelect: { store.select() }))]
    return ForEach(snapshots: rows, id: \.id) { row in row.content }
}

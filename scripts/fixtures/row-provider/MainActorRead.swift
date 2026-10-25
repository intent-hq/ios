import SwiftUI

@MainActor final class Store {
    var title = "Live title"
}

@MainActor func unsafeRows(_ store: Store) -> some View {
    ForEach(snapshots: [1], id: \.self) { _ in Text(store.title) }
}

import SwiftUI

extension ForEach where Data.Element: Sendable, Content: View {
    nonisolated init(
        snapshots: Data,
        id: KeyPath<Data.Element, ID>,
        @ViewBuilder content: @escaping @Sendable (Data.Element) -> Content
    ) {
        self.init(snapshots, id: id, content: content)
    }
}

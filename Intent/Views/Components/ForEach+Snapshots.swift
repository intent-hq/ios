import SwiftUI

extension ForEach where Data.Element: Sendable, Content: View {
    /// A deferred row provider that cannot inherit the caller's actor isolation.
    /// Prepare snapshots and main-actor actions before this call. The builder may
    /// run on SwiftUI's async renderer, so it must only use the supplied values.
    /// Store lightweight View values in snapshots; their bodies remain lazy.
    /// Returning ForEach directly preserves lazy containers' row identity/counts.
    nonisolated init(
        snapshots: Data,
        id: KeyPath<Data.Element, ID>,
        @ViewBuilder content: @escaping @Sendable (Data.Element) -> Content
    ) {
        self.init(snapshots, id: id, content: content)
    }
}

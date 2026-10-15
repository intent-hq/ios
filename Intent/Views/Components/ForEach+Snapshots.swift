import SwiftUI

extension ForEach where Data.Element: Sendable, Content: View {
    /// Use for deferred row lists prepared in a main-actor context.
    ///
    /// SwiftUI may call row builders on its async renderer. Plain ForEach content
    /// is not @Sendable, so a closure can inherit this target's default MainActor
    /// isolation, compile successfully, and crash when invoked off the main actor.
    /// See https://github.com/intent-hq/ios/pull/796.
    ///
    /// Sendable snapshots and a @Sendable builder make accidental direct access to
    /// main-actor state a compile error. Read store state and prepare main-actor
    /// actions before this call; the deferred builder should use prepared values.
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

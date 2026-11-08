import SwiftUI

@MainActor func unsafeRows() -> some View {
    let builder: @MainActor @Sendable (Int) -> Text = { Text("Row \($0)") }
    return ForEach(snapshots: [1], id: \.self, content: builder)
}

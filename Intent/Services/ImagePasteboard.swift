import UIKit

@MainActor
struct ImagePasteboard {
    var hasImages: () -> Bool
    var itemTypes: () -> [[String]]
    var data: (_ type: String, _ index: Int) -> Data?

    static let general = Self(
        hasImages: { UIPasteboard.general.hasImages },
        itemTypes: { UIPasteboard.general.types(forItemSet: nil) ?? [] },
        data: { type, index in
            UIPasteboard.general.data(forPasteboardType: type, inItemSet: IndexSet(integer: index))?.first
        }
    )
}

import Foundation

nonisolated struct FileLineIndex: Sendable {
    let starts: [Int]

    init(_ source: String) {
        let text = source as NSString // swiftlint:disable:this legacy_objc_type
        var starts = [0]
        var cursor = 0
        while cursor < text.length {
            var end = cursor
            var contentEnd = cursor
            text.getLineStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: cursor, length: 0))
            if contentEnd < end { starts.append(end) }
            cursor = end
        }
        self.starts = starts
    }

    func line(at offset: Int) -> Int {
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if starts[middle] <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(1, lower)
    }
}

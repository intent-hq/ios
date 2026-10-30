import Foundation
import UIKit

nonisolated struct FileSyntaxRun: Decodable, Sendable {
    let location: Int
    let length: Int
    let color: String

    var range: NSRange { NSRange(location: location, length: length) }

    private struct Response: Decodable {
        let runs: [FileSyntaxRun]
    }

    static func decode(_ json: String, source: String) -> [Self] {
        let maximumRuns = 60_000
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(json.utf8)),
              response.runs.count <= maximumRuns else { return [] }
        let count = source.utf16.count
        var previousEnd = 0
        for run in response.runs {
            guard run.location >= previousEnd, run.length > 0,
                  run.location <= count, run.length <= count - run.location,
                  run.rgb != nil else { return [] }
            previousEnd = run.location + run.length
        }
        return response.runs
    }

    private var rgb: UInt32? {
        let hexDigits = 6
        let radix = 16
        guard color.first == "#", color.count == hexDigits + 1,
              color.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(color.dropFirst(), radix: radix)
    }

    @MainActor
    var uiColor: UIColor {
        guard let rgb else { return .label }
        // swiftlint:disable no_magic_numbers
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
        // swiftlint:enable no_magic_numbers
    }
}

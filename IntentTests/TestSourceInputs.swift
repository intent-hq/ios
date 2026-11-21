import Foundation
import Testing

enum TestSourceInputs {
    static var root: URL {
        Bundle(for: BundleToken.self).bundleURL
            .appendingPathComponent("TestSourceInputs", isDirectory: true)
    }

    static func url(for relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            """
            packaged source input \(relativePath) is missing at \(url.path); \
            check the IntentTests target's "Copy Test Source Inputs" phase \
            in Intent.xcodeproj.
            """
        )
        return url
    }

    private final class BundleToken {}
}

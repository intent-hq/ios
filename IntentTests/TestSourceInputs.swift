import Foundation
import Testing

/// Repository files that the source-backed suites (InfoPlistSyncTests,
/// PlatformGuardAllowlistTests) inspect at runtime.
///
/// The IntentTests target packages them into IntentTests.xctest through its
/// Copy Bundle Resources phase — folder references for `Intent/` and
/// `IntentTests/` plus `Info-visionOS.plist`, grouped as "Test Source Inputs"
/// in the project — so every build carries a verbatim copy of the current
/// tree. Tests resolve repo-relative paths against that copy instead of
/// deriving a repository root from compile-time `#filePath`: the checkout
/// the bundle was compiled in does not exist on a physical device and may be
/// gone or stale for a relocated build (intent-hq/ios#320). A missing
/// resource is a wiring error and fails loudly here; it is never a skip.
enum TestSourceInputs {

    /// The packaged copy of the repository root: the test bundle itself.
    static var root: URL { Bundle(for: BundleToken.self).bundleURL }

    /// URL of the packaged copy of a repo-relative path, required to exist.
    static func url(for relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            """
            packaged source input \(relativePath) is missing at \(url.path); \
            check the IntentTests target's Copy Bundle Resources phase \
            ("Test Source Inputs" in Intent.xcodeproj).
            """
        )
        return url
    }

    private final class BundleToken {}
}

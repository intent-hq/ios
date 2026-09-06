import Foundation
import Testing

/// Info-visionOS.plist is a full copy of Intent/Info.plist (selected via the
/// SDK-conditioned INFOPLIST_FILE build setting) plus the two dictation usage
/// strings that must not appear on iOS. The duplication is deliberate — the
/// per-SDK INFOPLIST_KEY_ route leaves empty usage keys in the built iOS
/// plist — so this test enforces the sync: every iOS key must be mirrored
/// verbatim, and the visionOS extras must be exactly the dictation pair.
struct InfoPlistSyncTests {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // IntentTests/
        .deletingLastPathComponent()  // repo root

    private func loadPlist(_ relativePath: String) throws -> [String: Any] {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any], "\(relativePath) is not a dictionary plist")
    }

    @Test func visionOSPlistMirrorsSharedKeysAndAddsOnlyDictationUsage() throws {
        let ios = try loadPlist("Intent/Info.plist")
        let visionOS = try loadPlist("Info-visionOS.plist")

        for (key, iosValue) in ios {
            let visionOSValue = try #require(
                visionOS[key],
                "Info-visionOS.plist is missing key \(key) from Intent/Info.plist"
            )
            #expect(
                (iosValue as? NSObject) == (visionOSValue as? NSObject),
                "Info-visionOS.plist value for \(key) diverged from Intent/Info.plist"
            )
        }

        let extraKeys = Set(visionOS.keys).subtracting(ios.keys)
        #expect(
            extraKeys == [
                "NSMicrophoneUsageDescription",
                "NSSpeechRecognitionUsageDescription",
            ],
            "Info-visionOS.plist extras must be exactly the dictation usage keys"
        )
    }
}

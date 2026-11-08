import Foundation
import Testing

/// Info-visionOS.plist is a full copy of Intent/Info.plist (selected via the
/// SDK-conditioned INFOPLIST_FILE build setting) plus the two dictation usage
/// strings that must not appear on iOS. The duplication is deliberate — the
/// per-SDK INFOPLIST_KEY_ route leaves empty usage keys in the built iOS
/// plist — so this test enforces the sync: every iOS key must be mirrored
/// verbatim, and the visionOS extras must be exactly the dictation pair.
/// Both plists are read from the copies packaged into the test bundle (see
/// TestSourceInputs), not from the checkout.
struct InfoPlistSyncTests {
    @Test func builtAppSupportsOnlyUprightPortraitOnIPhone() throws {
        // Read the built declaration, not Bundle's current-device dictionary:
        // an iPad runtime may omit the iPhone-qualified entry from that view.
        let data = try Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let orientations = plist["UISupportedInterfaceOrientations~iphone"]
            ?? plist["UISupportedInterfaceOrientations"]
        #expect(
            orientations as? [String] == ["UIInterfaceOrientationPortrait"]
        )
    }

    private func loadPlist(_ relativePath: String) throws -> [String: Any] {
        let url = try TestSourceInputs.url(for: relativePath)
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
                "NSSpeechRecognitionUsageDescription"
            ],
            "Info-visionOS.plist extras must be exactly the dictation usage keys"
        )
    }

    /// Multi-scene support is a shared key (pinned-backend windows via
    /// WindowGroup(for: BackendID.self) on visionOS and iPad). The mirror
    /// check above keeps the plists in sync; this pins the value so a
    /// regression fails deliberately, not via a missing-key sync error.
    @Test func bothPlistsDeclareMultipleSceneSupport() throws {
        for path in ["Intent/Info.plist", "Info-visionOS.plist"] {
            let plist = try loadPlist(path)
            let manifest = try #require(
                plist["UIApplicationSceneManifest"] as? [String: Any],
                "\(path) is missing UIApplicationSceneManifest")
            #expect(
                manifest["UIApplicationSupportsMultipleScenes"] as? Bool == true,
                "\(path) must declare UIApplicationSupportsMultipleScenes = true")
        }
    }
}

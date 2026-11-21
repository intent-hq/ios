import Foundation
import Testing

struct InfoPlistSyncTests {
    @Test func builtAppSupportsOnlyUprightPortraitOnIPhone() throws {
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

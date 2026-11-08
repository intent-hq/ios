#if DEBUG
import Foundation

extension DemoFixtures {
    static var usesTranscriptVideo: Bool {
        let arguments = LaunchOptions.current.arguments
        return DemoMode.demoDataRequested(by: arguments) && arguments.contains("--demo-transcript-video")
    }

    static var transcriptVideoMessages: [[String: Any]] {
        [
            [
                "id": "demo-video-user", "role": "user", "timestamp": transcriptIso(minutesAgo: 2),
                "contentBlocks": [
                    ["type": "text", "text": "Here is the recording."],
                    [
                        "type": "file", "attachmentId": "demo-video-attachment",
                        "fileName": "Recording.mp4", "mimeType": "video/mp4"
                    ]
                ]
            ],
            [
                "id": "demo-video-assistant", "role": "assistant", "timestamp": transcriptIso(minutesAgo: 1),
                "contentBlocks": [["type": "text", "text": "Recording received."]]
            ]
        ]
    }

    static func transcriptVideoResponse(for method: String, params: [String: Any]) -> Any? {
        guard usesTranscriptVideo else { return nil }
        let path = ".intent/attachments/demo-recording.mp4"
        switch method {
        case "file.getAttachmentInfo" where params["attachmentId"] as? String == "demo-video-attachment":
            return ["path": path, "exists": true]
        case "file.readChunk" where params["path"] as? String == path
            && params["workspaceId"] as? String == "demo-ws-dashboard":
            let offset = params["offset"] as? Int ?? 0
            let length = params["length"] as? Int ?? 0
            guard offset >= 0, offset <= transcriptVideoBytes.count, length > 0 else { return [:] }
            let chunk = transcriptVideoBytes.dropFirst(offset).prefix(length)
            return [
                "content": chunk.base64EncodedString(), "bytesRead": chunk.count,
                "size": transcriptVideoBytes.count
            ]
        default:
            return nil
        }
    }

    // Two-second H.264 MP4, 160×90: yellow square on steel-blue background.
    // Generated once with ffmpeg color + drawbox, libx264, yuv420p, +faststart.
    // Inline bytes keep the opt-in demo independent of network and bundle lookup.
    private static let transcriptVideoBytes = Data(
        base64Encoded: transcriptVideoBase64,
        options: .ignoreUnknownCharacters
    ) ?? Data()
    private static let transcriptVideoBase64 = """
    AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMybW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAB9AAAQAAAQAA
    AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA
    Al10cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAB9AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA
    AAAAAAAAAAAAAABAAAAAAKAAAABaAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAfQAAAAAAABAAAAAAHVbWRpYQAAACBtZGhk
    AAAAAAAAAAAAAAAAAABAAAAAgABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABgG1p
    bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAUBzdGJsAAAAwHN0c2QA
    AAAAAAAAAQAAALBhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAKAAWgBIAAAASAAAAAAAAAABFExhdmM2My4xLjEwMiBsaWJ4
    MjY0AAAAAAAAAAAAAAAAGP//AAAANmF2Y0MBZAAK/+EAGWdkAAqs2UKN+TARAAADAAEAAAMAAg8SJZYBAAZo6+PLIsD9+PgAAAAA
    EHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAAD6AAAAAAAAAAGHN0dHMAAAAAAAAAAQAAAAIAAEAAAAAAFHN0c3MAAAAAAAAAAQAA
    AAEAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAIAAAABAAAAHHN0c3oAAAAAAAAAAAAAAAIAAAPYAAAAEAAAABRzdGNvAAAAAAAAAAEA
    AANiAAAAYXVkdGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAA
    HGRhdGEAAAABAAAAAExhdmY2My4xLjEwMgAAAAhmcmVlAAAD8G1kYXQAAAKtBgX//6ncRem95tlIt5Ys2CDZI+7veDI2NCAtIGNv
    cmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDov
    L3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MyBkZWJsb2NrPTE6MDowIGFuYWx5c2U9
    MHgzOjB4MTEzIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hy
    b21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0xIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zm
    c2V0PS0yIHRocmVhZHM9MyBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVy
    bGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTMgYl9weXJhbWlkPTIgYl9hZGFwdD0x
    IGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9MiBrZXlpbnQ9MjUwIGtleWludF9taW49MSBz
    Y2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTQwIHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0w
    LjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAASNliIQAFv/+7lT+BTI/t0t6
    ppP9mXXjqwvJTxtRV/pvULlpw2jjpimMU7GAEz/vvSmGoPPpww9Txm0R7NCBA+tSPJQmNGIXQvKAvishGAzTAwqUmhhECwfZBFqK
    zZGFFJ/uaaOnb+wjJMiVMnNnwkiY9LyBII+J7z/J+I597kwYoHfPyVWJPFVA+EkI3AjdbqHm4BTcozzDOoylDMrXSxDYlCkn5Jja
    VxRHMcGOAYsFRcACv6rxbam9lfG/jyJMg4fH4SrwQGexQSRsOLYAgXy2SJU1F+GAHi+ll3I8yQ4kTW/c2Lb3M212zgMDM+K30F2N
    N1wBXFzG/cq276+lidw5+XI6ggwb4HdCVBORzEV3h7lB2dIrIbuFUGndLmVgw5WRHUsAAAAMQZohbEFf/talUAPy
    """
}
#endif

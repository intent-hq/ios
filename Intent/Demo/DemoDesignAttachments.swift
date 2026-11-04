#if DEBUG
import Foundation

/// In-memory upload/read RPCs for attachments sent to the design demo workspace.
@MainActor
final class DemoDesignAttachments {
    private struct Attachment {
        let id: String
        let name: String
        let mimeType: String
        let data: Data
        var path: String { ".intent/attachments/\(id)/\(name)" }
    }

    private var attachments: [String: Attachment] = [:]

    func response(for method: String, params: [String: Any]) -> Any? {
        switch method {
        case "file.placeAttachment" where params["workspaceId"] as? String == DemoDesignFixtures.workspaceId:
            guard let encoded = params["data"] as? String, let data = Data(base64Encoded: encoded),
                  let name = params["fileName"] as? String else { return nil }
            let id = "demo-design-attachment-\(UUID().uuidString)"
            let attachment = Attachment(id: id, name: name, mimeType: params["mimeType"] as? String ?? "application/octet-stream", data: data)
            attachments[id] = attachment
            return ["attachmentId": id, "fileName": name, "path": attachment.path, "size": data.count, "mimeType": attachment.mimeType]
        case "file.getAttachmentInfo":
            guard let id = params["attachmentId"] as? String, let attachment = attachments[id] else { return nil }
            return ["path": attachment.path, "exists": true]
        case "file.readChunk" where params["workspaceId"] as? String == DemoDesignFixtures.workspaceId:
            guard let attachment = attachments.values.first(where: { $0.path == params["path"] as? String }),
                  let offset = params["offset"] as? Int, let length = params["length"] as? Int,
                  offset >= 0, offset <= attachment.data.count, length > 0 else { return nil }
            let chunk = attachment.data.dropFirst(offset).prefix(length)
            return ["content": chunk.base64EncodedString(), "bytesRead": chunk.count, "size": attachment.data.count]
        default:
            return nil
        }
    }
}
#endif

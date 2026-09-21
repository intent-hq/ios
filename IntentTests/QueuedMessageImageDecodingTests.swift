import Foundation
@testable import Intent
import Testing

extension QueuedMessageTests {
    @Test func imageBlocksDropOnlyMalformedElements() throws {
        let json = """
        {"id":"q-mixed","content":"images","queuedAt":"2025-01-01T00:00:00Z","position":4,
        "imageBlocks":[
          {"type":"image","data":"inline","mimeType":"image/png"},
          {"type":42}, "primitive", null, {},
          {"type":"image","attachmentId":"att-2"}
        ],"messageMetadata":{"userAppMessageId":"uam-1"}}
        """

        let decoded = try JSONDecoder().decode(QueuedMessage.self, from: Data(json.utf8))

        #expect(decoded.imageBlocks.count == 2)
        #expect(decoded.imageBlocks.first?.data == "inline")
        #expect(decoded.imageBlocks.first?.mimeType == "image/png")
        #expect(decoded.imageBlocks.last?.attachmentId == "att-2")
        #expect(decoded.hasReportedImageBlocks)
        #expect(decoded.messageMetadata["userAppMessageId"]?.stringValue == "uam-1")
    }

    @Test func imageBlockReportingDistinguishesArraysFromMalformedFields() throws {
        let cases = [
            (field: "", reported: false),
            (field: ",\"imageBlocks\":null", reported: false),
            (field: ",\"imageBlocks\":{}", reported: false),
            (field: ",\"imageBlocks\":[]", reported: true),
            (field: ",\"imageBlocks\":[null,42,{}, {\"type\":false}]", reported: true)
        ]

        for testCase in cases {
            let json = """
            {"id":"q-presence","content":"images","queuedAt":"2025-01-01T00:00:00Z","position":0\
            \(testCase.field)}
            """
            let decoded = try JSONDecoder().decode(QueuedMessage.self, from: Data(json.utf8))
            #expect(decoded.imageBlocks.isEmpty)
            #expect(decoded.hasReportedImageBlocks == testCase.reported)

            let encoded = try JSONEncoder().encode(decoded)
            let object = try #require(
                try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            #expect((object["imageBlocks"] != nil) == testCase.reported)
            if testCase.reported {
                #expect((object["imageBlocks"] as? [Any])?.isEmpty == true)
            }

            let roundTripped = try JSONDecoder().decode(QueuedMessage.self, from: encoded)
            #expect(roundTripped.hasReportedImageBlocks == testCase.reported)
        }
    }
}

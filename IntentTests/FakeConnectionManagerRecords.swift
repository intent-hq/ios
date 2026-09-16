import Foundation

struct FakeConnectRecord {
    let hosts: [String]
    let port: Int
    let token: String
    let certFingerprint: String?
    let tcAddress: String?
}

struct FakeCredentialUpdateRecord {
    let hosts: [String]
    let port: Int
    let token: String
    let certFingerprint: String?
    let tcAddress: String?
}

struct FakeRequestRecord {
    let method: String
    let params: [String: Any]
    let timestamp: Date
}

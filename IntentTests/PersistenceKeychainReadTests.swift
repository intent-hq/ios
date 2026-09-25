import Foundation
@testable import Intent
import Security
import Testing

extension SecItemKeychainStorageTests {
    @Test func readsDistinguishMissingValueAndOSStatusFailures() {
        let fake = FakeSecItemStore()
        let storage = SecItemKeychainStorage(security: fake.securityCalls())
        let service = "read-test.service"
        let account = "read-test.account"
        #expect(storage.load(service: service, account: account) == .missing)
        let data = Data("fixture".utf8)
        #expect(storage.save(data: data, service: service, account: account))
        #expect(storage.load(service: service, account: account) == .value(data))

        for status in [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed] {
            fake.readFailures[account] = status
            #expect(storage.load(service: service, account: account) == .unavailable(status))
        }
        fake.readFailures = [:]
        #expect(storage.load(service: service, account: account) == .value(data))
        #expect(fake.deleteCallCount == 0)
    }

    @Test func successfulReadWithoutDataIsMalformedNotMissing() {
        let fake = FakeSecItemStore()
        let storage = SecItemKeychainStorage(security: fake.securityCalls())
        fake.readOverride = (errSecSuccess, nil)
        #expect(storage.load(service: "test", account: "test") == .malformed)
        fake.readOverride = (errSecSuccess, 12 as AnyObject)
        #expect(storage.load(service: "test", account: "test") == .malformed)
    }

    @Test func localReadQueryRetainsCredentialIdentityAndScope() throws {
        let fake = FakeSecItemStore()
        let storage = SecItemKeychainStorage(security: fake.securityCalls())
        #expect(storage.load(service: "test.service", account: "test.account") == .missing)
        let query = try #require(fake.readQueries.first)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "test.service")
        #expect(query[kSecAttrAccount as String] as? String == "test.account")
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(query[kSecAttrSynchronizable as String] == nil)
        #expect(query[kSecAttrAccessGroup as String] == nil)
        #expect(query[kSecAttrAccessible as String] == nil)
    }
}

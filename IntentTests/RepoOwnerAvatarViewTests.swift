import Foundation
@testable import Intent
import Testing

struct RepoOwnerAvatarViewTests {
    @Test func avatarURLForOwner() {
        let url = RepoOwnerAvatarView.avatarURL(for: "octocat")
        #expect(url?.absoluteString == "https://github.com/octocat.png?size=64")
    }

    @Test func avatarURLForNilOwner() {
        #expect(RepoOwnerAvatarView.avatarURL(for: nil) == nil)
    }

    @Test func avatarURLForEmptyOwner() {
        #expect(RepoOwnerAvatarView.avatarURL(for: "") == nil)
    }
}

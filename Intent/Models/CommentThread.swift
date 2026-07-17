import Foundation

/// A comment thread summary returned by comment.subscribe.
/// Maps to CommentThreadSummary from intentd (intent-core/src/model.rs).
struct CommentThread: Identifiable, Equatable {
    let threadId: String
    let noteId: String
    let targetedText: String?
    let anchorId: String?
    let status: String
    let createdAt: String
    let lastActivity: String
    let latestCommentAuthor: String
    let latestCommentAuthorType: String
    let latestCommentAt: String
    let commentCount: Int
    
    var id: String { threadId }
    
    static func parseThread(_ dict: [String: Any]) -> CommentThread? {
        guard let threadId = dict["threadId"] as? String,
              let noteId = dict["noteId"] as? String,
              let status = dict["status"] as? String,
              let createdAt = dict["createdAt"] as? String,
              let lastActivity = dict["lastActivity"] as? String,
              let latestCommentAuthor = dict["latestCommentAuthor"] as? String,
              let latestCommentAuthorType = dict["latestCommentAuthorType"] as? String,
              let latestCommentAt = dict["latestCommentAt"] as? String,
              let commentCount = dict["commentCount"] as? Int else {
            return nil
        }
        
        return CommentThread(
            threadId: threadId,
            noteId: noteId,
            targetedText: dict["targetedText"] as? String,
            anchorId: dict["anchorId"] as? String,
            status: status,
            createdAt: createdAt,
            lastActivity: lastActivity,
            latestCommentAuthor: latestCommentAuthor,
            latestCommentAuthorType: latestCommentAuthorType,
            latestCommentAt: latestCommentAt,
            commentCount: commentCount
        )
    }
}

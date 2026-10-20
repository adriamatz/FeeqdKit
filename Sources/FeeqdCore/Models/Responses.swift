import Foundation

/// `POST` / `DELETE …/vote`. The count is the server's: it replaces the optimistic one.
package struct VoteResult: Decodable, Equatable, Sendable {
    package let entryID: String
    package let voteCount: Int
    package let voted: Bool

    enum CodingKeys: String, CodingKey { case entryID = "entry_id", voteCount = "vote_count", voted }
}

/// `GET /sdk/boards/{b}/my-votes`: ids, not a flag per row, so the list stays cacheable and shared.
package struct MyVotes: Decodable, Sendable {
    package let entryIDs: [String]

    enum CodingKeys: String, CodingKey { case entryIDs = "entry_ids" }
}

/// `202 queued`. There is no entry id: the SDK can only refresh the list afterwards.
package struct SubmitReceipt: Decodable, Equatable, Sendable {
    package let status: String
    package let messageID: String?

    enum CodingKeys: String, CodingKey { case status, messageID = "message_id" }
}

package struct CreatedComment: Decodable, Equatable, Sendable {
    package let id: String
    package let entryID: String
    package let content: String
    package let moderationState: String?
    package let createdAt: Date?

    package var isPublished: Bool { moderationState == nil || moderationState == "published" }

    enum CodingKeys: String, CodingKey {
        case id, entryID = "entry_id", content, moderationState = "moderation_state", createdAt = "created_at"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        entryID = (try? c.decode(String.self, forKey: .entryID)) ?? ""
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        moderationState = try? c.decode(String.self, forKey: .moderationState)
        createdAt = try? c.decode(Date.self, forKey: .createdAt)
    }
}

/// A possible duplicate, suggested while someone types a title. Advice only, never a block.
package struct SimilarEntry: Decodable, Identifiable, Hashable, Sendable {
    package let id: String
    package let title: String

    enum CodingKeys: String, CodingKey { case id, title, content }

    private struct Content: Decodable { let title: String? }

    package init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? (try? c.decode(Content.self, forKey: .content))?.title ?? ""
    }
}

package struct SimilarResponse: Decodable, Sendable {
    package let items: [SimilarEntry]

    enum CodingKeys: String, CodingKey { case items }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = ((try? c.decode([Lossy<SimilarEntry>].self, forKey: .items)) ?? []).compactMap(\.value)
    }
}

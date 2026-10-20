import Foundation

/// One request or bug, as the public list and the detail endpoint return it.
///
/// The list already carries `vote_count` and `comment_count`, so a row never needs a request
/// of its own, and the board is paged instead of fetched whole.
package struct Entry: Decodable, Identifiable, Hashable, Sendable {
    package let id: String
    package let boardID: String
    package let title: String
    package let details: String?
    /// `nil` when the board hides authors, or nobody signed it. Rendered as "Anonymous", never blank.
    package let authorName: String?
    /// The status slug. Its label and colour come from the config's statuses.
    package let state: String
    package let createdAt: Date
    package var voteCount: Int
    package let commentCount: Int
    /// The user's own request that nobody else sees yet: held for review, or on a status the
    /// board keeps out of the app. It cannot be voted or commented on until it is published.
    package var onlyYou: Bool

    package init(
        id: String,
        boardID: String,
        title: String,
        details: String? = nil,
        authorName: String? = nil,
        state: String = "pending",
        createdAt: Date = Date(),
        voteCount: Int = 0,
        commentCount: Int = 0,
        onlyYou: Bool = false
    ) {
        self.id = id
        self.boardID = boardID
        self.title = title
        self.details = details
        self.authorName = authorName
        self.state = state
        self.createdAt = createdAt
        self.voteCount = voteCount
        self.commentCount = commentCount
        self.onlyYou = onlyYou
    }

    enum CodingKeys: String, CodingKey {
        case id, boardID = "board_id", content, authorName = "author_name", state, createdAt = "created_at"
        case voteCount = "vote_count", commentCount = "comment_count", onlyYou = "only_you"
    }

    private struct Content: Decodable {
        let title: String?
        let description: String?
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        boardID = (try? c.decode(String.self, forKey: .boardID)) ?? ""
        let content = try? c.decode(Content.self, forKey: .content)
        title = content?.title?.feeqdTrimmed ?? ""
        let description = content?.description?.feeqdTrimmed
        details = (description?.isEmpty ?? true) ? nil : description
        authorName = try? c.decode(String.self, forKey: .authorName)
        state = (try? c.decode(String.self, forKey: .state)) ?? "pending"
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        voteCount = (try? c.decode(Int.self, forKey: .voteCount)) ?? 0
        commentCount = (try? c.decode(Int.self, forKey: .commentCount)) ?? 0
        onlyYou = (try? c.decode(Bool.self, forKey: .onlyYou)) ?? false
    }
}

package struct Pagination: Decodable, Equatable, Sendable {
    package let page: Int
    package let pageSize: Int
    package let totalItems: Int
    package let totalPages: Int
    package let hasNext: Bool

    package init(page: Int, pageSize: Int, totalItems: Int, totalPages: Int, hasNext: Bool) {
        self.page = page
        self.pageSize = pageSize
        self.totalItems = totalItems
        self.totalPages = totalPages
        self.hasNext = hasNext
    }

    enum CodingKeys: String, CodingKey {
        case page, pageSize = "page_size", totalItems = "total_items", totalPages = "total_pages", hasNext = "has_next"
    }
}

package struct Page<Item: Decodable & Sendable>: Decodable, Sendable {
    package let items: [Item]
    package let pagination: Pagination

    package init(items: [Item], pagination: Pagination) {
        self.items = items
        self.pagination = pagination
    }

    enum CodingKeys: String, CodingKey { case items, pagination }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([Lossy<Item>].self, forKey: .items).compactMap(\.value)
        pagination = try c.decode(Pagination.self, forKey: .pagination)
    }
}

/// A comment. They arrive flat with `parent_id`; the one-level tree is built on the client.
package struct Comment: Decodable, Identifiable, Hashable, Sendable {
    package let id: String
    package let parentID: String?
    package let content: String
    package let authorName: String?
    /// The team's answer is what turns a board into a conversation: marked, and pinned first.
    package let isTeamMember: Bool
    package let isPinned: Bool
    package let createdAt: Date
    /// Local only: a comment just written that the board holds for moderation.
    package var isPendingModeration: Bool

    package init(
        id: String,
        parentID: String?,
        content: String,
        authorName: String?,
        isTeamMember: Bool,
        isPinned: Bool,
        createdAt: Date,
        isPendingModeration: Bool = false
    ) {
        self.id = id
        self.parentID = parentID
        self.content = content
        self.authorName = authorName
        self.isTeamMember = isTeamMember
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.isPendingModeration = isPendingModeration
    }

    enum CodingKeys: String, CodingKey {
        case id, parentID = "parent_id", content, authorName = "author_name"
        case isTeamMember = "is_team_member", isPinned = "is_pinned", createdAt = "created_at"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        parentID = try? c.decode(String.self, forKey: .parentID)
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        authorName = try? c.decode(String.self, forKey: .authorName)
        isTeamMember = (try? c.decode(Bool.self, forKey: .isTeamMember)) ?? false
        isPinned = (try? c.decode(Bool.self, forKey: .isPinned)) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        isPendingModeration = false
    }
}

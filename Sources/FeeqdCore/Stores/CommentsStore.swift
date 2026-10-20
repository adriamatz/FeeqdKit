import Combine
import Foundation

/// The comments under one entry, as one-level threads.
@MainActor
package final class CommentsStore: ObservableObject {
    package enum Phase: Equatable {
        case loading, loaded
        case failed(FeeqdError)
    }

    package struct Thread: Identifiable, Equatable {
        package let root: Comment
        package let replies: [Comment]
        package var id: String { root.id }
    }

    @Published package private(set) var phase: Phase = .loading
    @Published package private(set) var comments: [Comment] = []
    @Published package private(set) var isSending = false
    @Published package var lastError: FeeqdError?

    private let client: FeeqdClient
    private let boardID: String
    private let entryID: String

    package init(client: FeeqdClient, boardID: String, entryID: String) {
        self.client = client
        self.boardID = boardID
        self.entryID = entryID
    }

    /// Pinned roots first — the team's answer should read as the answer — then oldest first.
    package var threads: [Thread] {
        let roots = comments
            .filter { $0.parentID == nil }
            .sorted { ($0.isPinned ? 0 : 1, $0.createdAt) < ($1.isPinned ? 0 : 1, $1.createdAt) }
        return roots.map { root in
            Thread(root: root, replies: comments.filter { $0.parentID == root.id }.sorted { $0.createdAt < $1.createdAt })
        }
    }

    package func load() async {
        do {
            comments = try await client.comments(boardID: boardID, entryID: entryID, page: 1, pageSize: 100).items
            phase = .loaded
        } catch {
            if FeeqdError.isCancellation(error) { return }
            let wrapped = FeeqdError.wrap(error)
            if comments.isEmpty {
                phase = .failed(wrapped)
            } else {
                lastError = wrapped
            }
        }
    }

    /// Replies only to a root: the backend rejects a reply to a reply (`400 invalid_parent`).
    @discardableResult
    package func send(content: String, parentID: String? = nil) async -> Bool {
        let text = content.feeqdTrimmed
        guard !text.isEmpty, !isSending else { return false }
        isSending = true
        defer { isSending = false }
        do {
            let created = try await client.comment(boardID: boardID, entryID: entryID, content: text, parentID: parentID)
            comments.append(
                Comment(
                    id: created.id,
                    parentID: parentID,
                    content: created.content.isEmpty ? text : created.content,
                    authorName: nil,
                    isTeamMember: false,
                    isPinned: false,
                    createdAt: created.createdAt ?? Date(),
                    isPendingModeration: !created.isPublished
                )
            )
            phase = .loaded
            return true
        } catch {
            lastError = FeeqdError.wrap(error)
            return false
        }
    }
}

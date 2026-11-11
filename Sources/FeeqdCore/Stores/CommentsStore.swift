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
    /// Written here and kept to go out later: shown in the thread, marked as not sent yet.
    @Published package private(set) var pendingComments: [Comment] = []
    @Published package private(set) var isSending = false
    /// Whether the thread takes comments. A request in review on a backend that cannot show its
    /// author the thread does not: writing there would go nowhere anyone reads.
    @Published package private(set) var isOpen = true
    @Published package var lastError: FeeqdError?

    private let client: FeeqdClient
    private let boardID: String
    private let entryID: String
    private var ownInReview = false
    private var pendingWatch: AnyCancellable?

    package init(client: FeeqdClient, boardID: String, entryID: String) {
        self.client = client
        self.boardID = boardID
        self.entryID = entryID
        pendingWatch = NotificationCenter.default.publisher(for: FeeqdClient.pendingWritesChanged)
            .sink { [weak self] _ in Task { await self?.pendingChanged() } }
    }

    /// Pinned roots first — the team's answer should read as the answer — then oldest first.
    package var threads: [Thread] {
        let all = comments + pendingComments
        let roots = all
            .filter { $0.parentID == nil }
            .sorted { ($0.isPinned ? 0 : 1, $0.createdAt) < ($1.isPinned ? 0 : 1, $1.createdAt) }
        return roots.map { root in
            Thread(root: root, replies: all.filter { $0.parentID == root.id }.sorted { $0.createdAt < $1.createdAt })
        }
    }

    /// `ownInReview` is a request this device sent that the public cannot see yet: its thread is
    /// the author's and the team's, read through the author's own route.
    package func load(ownInReview: Bool = false) async {
        self.ownInReview = ownInReview
        await loadPending()
        // Asked alongside the thread: the author's own comments the team has not approved yet,
        // which the thread itself never holds. Any failure, a backend without the route
        // included, leaves the thread as it reads on its own.
        async let held = (try? client.myPendingComments(boardID: boardID, entryID: entryID)) ?? []
        do {
            let thread = try await ownInReview
                ? client.myComments(boardID: boardID, entryID: entryID, page: 1, pageSize: 100).items
                : client.comments(boardID: boardID, entryID: entryID, page: 1, pageSize: 100).items
            comments = Self.merging(held: await held, into: thread)
            isOpen = true
            phase = .loaded
        } catch {
            if FeeqdError.isCancellation(error) { return }
            if ownInReview, (error as? FeeqdError)?.isMissingRoute == true {
                comments = []
                isOpen = false
                phase = .loaded
                return
            }
            let wrapped = FeeqdError.wrap(error)
            if comments.isEmpty {
                phase = .failed(wrapped)
            } else {
                lastError = wrapped
            }
        }
    }

    /// The thread with the author's held comments added, once each. One the thread already has
    /// was published meanwhile: the thread's copy, a normal comment, is the one kept.
    package static func merging(held: [Comment], into thread: [Comment]) -> [Comment] {
        var seen = Set(thread.map(\.id))
        return thread + held.filter { seen.insert($0.id).inserted }
    }

    /// Replies only to a root: the backend rejects a reply to a reply (`400 invalid_parent`).
    @discardableResult
    package func send(content: String, parentID: String? = nil) async -> Bool {
        let text = content.feeqdTrimmed
        guard !text.isEmpty, !isSending else { return false }
        isSending = true
        defer { isSending = false }
        let key = UUID().uuidString
        do {
            let created = try await client.comment(
                boardID: boardID, entryID: entryID, content: text, parentID: parentID, idempotencyKey: key
            )
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
            let wrapped = FeeqdError.wrap(error)
            guard await client.canKeepForLater(wrapped) else {
                lastError = wrapped
                return false
            }
            // Kept, and the draft cleared: sending it again from the field would post it twice.
            let write = PendingWrite(id: key, kind: .comment(boardID: boardID, entryID: entryID, content: text, parentID: parentID))
            await client.keepForLater(write)
            await loadPending()
            phase = .loaded
            return true
        }
    }

    private func loadPending() async {
        pendingComments = await client.pendingWrites().compactMap { write in
            guard case let .comment(board, entry, content, parentID) = write.kind, board == boardID, entry == entryID else { return nil }
            return Comment(
                id: write.id, parentID: parentID, content: content, authorName: nil, isTeamMember: false, isPinned: false,
                createdAt: write.createdAt, isPendingSend: true
            )
        }
    }

    /// One that was pending went out (or was dropped): the thread reads the server's copy.
    private func pendingChanged() async {
        let before = Set(pendingComments.map(\.id))
        await loadPending()
        if !before.isSubset(of: Set(pendingComments.map(\.id))) { await load(ownInReview: ownInReview) }
    }
}

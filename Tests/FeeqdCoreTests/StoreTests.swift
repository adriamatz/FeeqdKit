import FeeqdCore
import XCTest

@MainActor
final class StoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func routeCapturedResponses(vote: StubURLProtocol.Response? = nil) throws {
        let config = try Fixture.data("sdk_config")
        let page = try Fixture.data("entries_page")
        let votes = try Fixture.data("my_votes")
        StubURLProtocol.responder = { request in
            let path = request.url?.path ?? ""
            if path == "/sdk/config" { return .json(200, config) }
            if path.hasSuffix("/my-votes") { return .json(200, votes) }
            if path.hasSuffix("/vote"), let vote { return vote }
            if path.hasPrefix("/public/feedback/") { return .json(200, page) }
            return .init(status: 404)
        }
    }

    func testColdStartLoadsConfigPageAndOwnVotes() async throws {
        try routeCapturedResponses()
        let store = BoardStore(client: .stubbed())
        await store.load()

        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.boardID, "0003BNsEyndh34CwVCh2UokMmOD", "the board comes from the config")
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.votedIDs, ["0003BNsEyoDrlLzjZ55HPXmoCv3"])
        XCTAssertEqual(store.config.strings["es"]?["board.title"], "Sugerencias")
        XCTAssertTrue(
            StubURLProtocol.requests.contains { $0.url?.path.hasSuffix("/my-votes") == true },
            "my-votes at launch is what registers the device for the dashboard's onboarding"
        )
    }

    func testTheAuthorsHiddenRequestsComeFirstAndCannotBeVoted() async throws {
        let config = try Fixture.data("sdk_config")
        let page = try Fixture.data("entries_page")
        let votes = try Fixture.data("my_votes")
        let mine = Data(#"""
        {"items": [
          {"id": "own_hidden", "board_id": "b", "content": {"title": "Sent a minute ago"}, "state": "pending",
           "created_at": "2026-09-29T10:00:00", "vote_count": 0, "comment_count": 0, "only_you": true},
          {"id": "0003BNsEyoGOfJuscIuVNe605gW", "board_id": "b", "content": {"title": "Public one"}, "state": "planned",
           "created_at": "2026-09-20T10:00:00", "vote_count": 3, "comment_count": 0, "only_you": false}
        ]}
        """#.utf8)
        StubURLProtocol.responder = { request in
            let path = request.url?.path ?? ""
            if path == "/sdk/config" { return .json(200, config) }
            if path.hasSuffix("/my-votes") { return .json(200, votes) }
            if path.hasSuffix("/mine") { return .json(200, mine) }
            if path.hasPrefix("/public/feedback/") { return .json(200, page) }
            return .init(status: 404)
        }
        let store = BoardStore(client: .stubbed())
        await store.load()

        XCTAssertEqual(store.entries.first?.id, "own_hidden", "what the author just sent leads the list")
        XCTAssertEqual(store.entries.count, 4, "the public one the author also sent is not listed twice")
        XCTAssertEqual(store.entries(in: .mine).map(\.id), ["own_hidden", "0003BNsEyoGOfJuscIuVNe605gW"])

        await store.toggleVote(entryID: "own_hidden")
        XCTAssertFalse(store.votedIDs.contains("own_hidden"))
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.path.hasSuffix("own_hidden/vote") == true })
    }

    func testAnOlderBackendWithoutMineJustShowsThePublicList() async throws {
        try routeCapturedResponses()
        let store = BoardStore(client: .stubbed())
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertTrue(store.mine.isEmpty)
    }

    func testTheReportedFailureIsTheLoadNotAnEmptyBoard() async throws {
        StubURLProtocol.responder = { _ in .init(status: 503) }
        let store = BoardStore(client: .stubbed())
        await store.load()
        guard case .failed = store.phase else { return XCTFail("expected .failed, got \(store.phase)") }
    }

    /// A failed load (a section switch cancels it, too) is retried when the board shows again;
    /// a loaded one is not fetched twice.
    func testAFailedBoardLoadsAgainALoadedOneDoesNot() async throws {
        let store = BoardStore(client: .stubbed())
        XCTAssertTrue(store.needsLoad)
        StubURLProtocol.responder = { _ in .init(status: 503) }
        await store.load()
        XCTAssertTrue(store.needsLoad)
        try routeCapturedResponses()
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertFalse(store.needsLoad)
    }

    func testVoteTakesTheServersCount() async throws {
        let target = "0003BNsEyoGOfJuscIuVNe605gW"
        let reply = Data(#"{"board_id": "b", "entry_id": "\#(target)", "vote_count": 7, "voted": true}"#.utf8)
        try routeCapturedResponses(vote: .json(200, reply))
        let store = BoardStore(client: .stubbed())
        await store.load()

        await store.toggleVote(entryID: target)
        XCTAssertEqual(store.entry(id: target)?.voteCount, 7)
        XCTAssertTrue(store.votedIDs.contains(target))
    }

    func testAFailedVoteIsRevertedAndReported() async throws {
        let target = "0003BNsEyoGOfJuscIuVNe605gW"
        try routeCapturedResponses(vote: .init(status: 500))
        let store = BoardStore(client: .stubbed())
        await store.load()
        let before = store.entry(id: target)?.voteCount

        await store.toggleVote(entryID: target)
        XCTAssertEqual(store.entry(id: target)?.voteCount, before)
        XCTAssertFalse(store.votedIDs.contains(target))
        XCTAssertNotNil(store.lastActionError)
    }

    func testTabsFilterByStatusCategory() async throws {
        try routeCapturedResponses()
        let store = BoardStore(client: .stubbed())
        await store.load()

        XCTAssertEqual(store.visibleTabs, [.open, .done])
        XCTAssertEqual(store.entries(in: .open).count, 3, "every captured entry is pending, an open status")
        XCTAssertEqual(store.entries(in: .done).count, 0)
    }

    func testTheRestOfTheBoardLoadsAfterTheFirstPage() async throws {
        let config = try Fixture.data("sdk_config")
        func page(_ number: Int, state: String, hasNext: Bool) -> Data {
            Data("""
            {"items": [{"id": "e\(number)", "board_id": "b", "content": {"title": "Entry \(number)"}, "state": "\(state)",
              "created_at": "2026-09-29T10:00:00", "vote_count": \(10 - number), "comment_count": 0}],
             "pagination": {"page": \(number), "page_size": 1, "total_items": 2, "total_pages": 2, "has_next": \(hasNext)}}
            """.utf8)
        }
        StubURLProtocol.responder = { request in
            let url = request.url
            let path = url?.path ?? ""
            if path == "/sdk/config" { return .json(200, config) }
            if path.hasPrefix("/public/feedback/") {
                let second = url?.query?.contains("page=2") == true
                return .json(200, second ? page(2, state: "planned", hasNext: false) : page(1, state: "completed", hasNext: true))
            }
            return .init(status: 404)
        }
        let store = BoardStore(client: .stubbed(), pageSize: 1)
        // The first page is all Done; the rest of the board comes in after it, so Open is not
        // left empty and its count is the board's.
        await store.load()
        XCTAssertEqual(store.entries(in: .open).map(\.id), ["e2"])
        XCTAssertEqual(store.count(in: .open).count, 1)
        XCTAssertTrue(store.count(in: .open).isComplete)
    }

    func testLoadMoreFollowsTheLastRowOfTheTab() async throws {
        try routeCapturedResponses()
        let store = BoardStore(client: .stubbed())
        await store.load()
        let lastOpen = try XCTUnwrap(store.entries(in: .open).last)
        // Nothing more to load in the fixture: the call is a no-op rather than a request.
        let before = StubURLProtocol.requests.count
        await store.loadMoreIfNeeded(current: lastOpen, in: .open)
        XCTAssertEqual(StubURLProtocol.requests.count, before)
    }

    func testCommentsBuildOneLevelThreads() async throws {
        let body = try Fixture.data("comments_page")
        StubURLProtocol.responder = { _ in .json(200, body) }
        let comments = CommentsStore(client: .stubbed(), boardID: "B", entryID: "E")
        await comments.load()

        XCTAssertEqual(comments.threads.count, 1)
        XCTAssertEqual(comments.threads.first?.replies.map(\.content), ["Same here."])
    }
}

import FeeqdCore
import XCTest

/// `Feeqd.boardStatus()`: what is new since the user last had the list on screen.
@MainActor
final class BoardNewsTests: XCTestCase {
    private let board = "b"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let suite = "BoardNewsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    private func entry(_ id: String, _ createdAt: String) -> String {
        #"{"id": "\#(id)", "board_id": "b", "content": {"title": "\#(id)"}, "state": "pending", "created_at": "\#(createdAt)", "vote_count": 0, "comment_count": 0}"#
    }

    /// Newest first, as `sort_by=recent` answers.
    private func route(page ids: [(String, String)], mine: [String] = []) {
        let page = Data(#"""
        {"items": [\#(ids.map { entry($0.0, $0.1) }.joined(separator: ","))],
         "pagination": {"page": 1, "page_size": 100, "total_items": \#(ids.count), "total_pages": 1, "has_next": false}}
        """#.utf8)
        let config = try? Fixture.data("sdk_config")
        let own = Data(#"{"items": [\#(mine.map { entry($0, "2026-10-01T10:00:00") }.joined(separator: ","))]}"#.utf8)
        StubURLProtocol.responder = { request in
            let path = request.url?.path ?? ""
            if path == "/sdk/config", let config { return .json(200, config) }
            if path.hasSuffix("/mine") { return .json(200, own) }
            if path.hasSuffix("/my-votes") { return .json(200, Data(#"{"entry_ids": []}"#.utf8)) }
            if path.hasPrefix("/public/feedback/") { return .json(200, page) }
            return .init(status: 404)
        }
    }

    private func seen(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    func testABoardNeverOpenedCountsNothingAndAsksNothing() async {
        route(page: [("new", "2026-10-02T10:00:00")])
        let count = await BoardNews.count(.stubbed(), lastSeen: BoardVisits(defaults: defaults).lastSeen([board]))
        XCTAssertEqual(count, 0, "never opened is 0, not the whole board")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testCountsWhatArrivedSinceTheLastVisitInOneRequest() async throws {
        route(page: [("c", "2026-10-03T10:00:00"), ("b", "2026-10-02T10:00:00"), ("a", "2026-09-30T10:00:00")])
        let visits = BoardVisits(defaults: defaults)
        visits.markSeen(board, at: try seen("2026-10-01T00:00:00Z"))

        let count = await BoardNews.count(.stubbed(), lastSeen: visits.lastSeen([board]))
        XCTAssertEqual(count, 2)
        let list = try XCTUnwrap(StubURLProtocol.requests.first { $0.url?.path == "/public/feedback/b" })
        XCTAssertTrue(list.url?.query?.contains("sort_by=recent") == true, "newest first: one page is enough")
    }

    func testNothingNewNeverAsksForOwnRequests() async throws {
        route(page: [("a", "2026-09-30T10:00:00")])
        let visits = BoardVisits(defaults: defaults)
        visits.markSeen(board, at: try seen("2026-10-01T00:00:00Z"))

        let count = await BoardNews.count(.stubbed(), lastSeen: visits.lastSeen([board]))
        XCTAssertEqual(count, 0)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testOwnRequestsAreNotNew() async throws {
        route(page: [("theirs", "2026-10-03T10:00:00"), ("mine", "2026-10-02T10:00:00")], mine: ["mine"])
        let visits = BoardVisits(defaults: defaults)
        visits.markSeen(board, at: try seen("2026-10-01T00:00:00Z"))

        let count = await BoardNews.count(.stubbed(), lastSeen: visits.lastSeen([board]))
        XCTAssertEqual(count, 1)
    }

    func testOpeningTheListBringsItBackToZero() async throws {
        route(page: [("c", "2026-10-03T10:00:00"), ("b", "2026-10-02T10:00:00")])
        let visits = BoardVisits(defaults: defaults)
        visits.markSeen(board, at: try seen("2026-10-01T00:00:00Z"))
        let client = FeeqdClient.stubbed()
        let before = await BoardNews.count(client, lastSeen: visits.lastSeen([board]))
        XCTAssertEqual(before, 2)

        let store = BoardStore(client: client, preferredBoardID: board, defaults: defaults)
        await store.load()
        XCTAssertEqual(store.entries.count, 2)
        // The device clock behind the server's: the newest row still counts as seen.
        store.markSeen(now: try seen("2026-09-01T00:00:00Z"))

        let after = await BoardNews.count(client, lastSeen: visits.lastSeen([board]))
        XCTAssertEqual(after, 0)
    }

    func testSignOutForgetsTheVisits() async throws {
        let visits = BoardVisits(defaults: defaults)
        visits.markSeen(board, at: Date())
        visits.clear()
        XCTAssertNil(visits.lastSeen(board))
    }

    func testCountsAcrossTheBoardsTheHubShows() throws {
        let config = try Fixture.decode(SDKConfig.self, "sdk_config")
        XCTAssertEqual(BoardNews.boardIDs(config: config, preferredBoardID: nil), ["0003BNsEyndh34CwVCh2UokMmOD"])
        XCTAssertEqual(BoardNews.boardIDs(config: config, preferredBoardID: "picked"), ["picked"])
    }
}

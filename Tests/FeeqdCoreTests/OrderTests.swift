@testable import FeeqdCore
import Foundation
import XCTest

/// With `userSort` on, the person picks the list's order; the choice outlives the screen.
@MainActor
final class OrderTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        defaults = UserDefaults(suiteName: "feeqd-order-\(UUID().uuidString)")
    }

    private func entry(_ id: String, _ state: String, votes: Int) -> [String: Any] {
        [
            "id": id, "board_id": "0003BNsEyndh34CwVCh2UokMmOD", "content": ["title": id], "state": state,
            "created_at": "2026-09-11T07:18:14", "type": "comment", "is_public": true, "vote_count": votes, "comment_count": 0,
        ]
    }

    /// The captured config with `userSort` set, and a page of requests in several statuses.
    private func route(userSort: Bool?) throws {
        var config = try JSONSerialization.jsonObject(with: Fixture.data("sdk_config")) as! [String: Any]
        var behaviour = config["behaviour"] as! [String: Any]
        behaviour["userSort"] = userSort
        config["behaviour"] = behaviour
        let configData = try JSONSerialization.data(withJSONObject: config)
        var page = try JSONSerialization.jsonObject(with: Fixture.data("entries_page")) as! [String: Any]
        page["items"] = [
            entry("A", "pending", votes: 9), entry("B", "in_progress", votes: 1), entry("C", "planned", votes: 3),
            entry("D", "in_progress", votes: 5), entry("E", "in_review", votes: 2),
        ]
        let pageData = try JSONSerialization.data(withJSONObject: page)
        let votes = try Fixture.data("my_votes")
        StubURLProtocol.responder = { request in
            let path = request.url?.path ?? ""
            if path == "/sdk/config" { return .json(200, configData) }
            if path.hasSuffix("/my-votes") { return .json(200, votes) }
            if path.hasPrefix("/public/feedback/") { return .json(200, pageData) }
            return .init(status: 404)
        }
    }

    private func lastSort() -> String? {
        StubURLProtocol.requests.last { $0.url?.path.hasPrefix("/public/feedback/") == true }
            .flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "sort_by" }?.value }
    }

    func testUserSortIsOffUnlessTheDashboardTurnsItOn() throws {
        let on = try JSONDecoder.feeqd.decode(SDKConfig.Behaviour.self, from: Data(#"{"userSort":true}"#.utf8))
        let unset = try JSONDecoder.feeqd.decode(SDKConfig.Behaviour.self, from: Data("{}".utf8))
        XCTAssertTrue(on.userSort)
        XCTAssertFalse(unset.userSort)
    }

    func testByStatusPutsTheFurthestAlongFirstThenTheMostVoted() async throws {
        try route(userSort: true)
        let store = BoardStore(client: .stubbed(), defaults: defaults)
        await store.load()
        await store.setOrder(.status)

        XCTAssertEqual(store.entries(in: .open).map(\.id), ["D", "B", "E", "C", "A"])
        XCTAssertEqual(store.entries(in: nil).map(\.id), ["D", "B", "E", "C", "A"])
    }

    func testByStatusGroupsTheListUnderEachStatus() async throws {
        try route(userSort: true)
        let store = BoardStore(client: .stubbed(), defaults: defaults)
        await store.load()
        await store.setOrder(.status)

        let groups = store.statusGroups(in: .open)
        XCTAssertEqual(groups.map(\.slug), ["in_progress", "in_review", "planned", "pending"])
        XCTAssertEqual(groups.map { $0.entries.map(\.id) }, [["D", "B"], ["E"], ["C"], ["A"]])
        XCTAssertEqual(groups.first?.status?.label, "In progress")
    }

    func testRowStyleIsCompactUnlessTheDashboardPicksAnother() throws {
        let cards = try JSONDecoder.feeqd.decode(SDKConfig.Behaviour.self, from: Data(#"{"rowStyle":"cards"}"#.utf8))
        let unknown = try JSONDecoder.feeqd.decode(SDKConfig.Behaviour.self, from: Data(#"{"rowStyle":"neon"}"#.utf8))
        let unset = try JSONDecoder.feeqd.decode(SDKConfig.Behaviour.self, from: Data("{}".utf8))
        XCTAssertEqual(cards.rowStyle, .cards)
        XCTAssertEqual(unknown.rowStyle, .compact)
        XCTAssertEqual(unset.rowStyle, .compact)
    }

    func testNewestAsksTheServerForTheNewestAndIsRemembered() async throws {
        try route(userSort: true)
        let store = BoardStore(client: .stubbed(), defaults: defaults)
        await store.load()
        XCTAssertEqual(lastSort(), "votes", "the dashboard's default to start with")

        await store.setOrder(.recent)
        XCTAssertEqual(lastSort(), "recent")
        XCTAssertEqual(store.order, .recent)

        StubURLProtocol.requests = []
        let reopened = BoardStore(client: .stubbed(), defaults: defaults)
        await reopened.load()
        XCTAssertEqual(reopened.order, .recent, "the choice outlives the screen")
        XCTAssertEqual(lastSort(), "recent")
    }

    func testWithoutUserSortTheDashboardsOrderAlwaysWins() async throws {
        defaults.set(ListOrder.recent.rawValue, forKey: BoardStore.orderKey)
        try route(userSort: nil)
        let store = BoardStore(client: .stubbed(), defaults: defaults)
        await store.load()
        XCTAssertEqual(store.order, .votes)
        XCTAssertEqual(lastSort(), "votes")
        XCTAssertFalse(store.canChangeOrder)
    }
}

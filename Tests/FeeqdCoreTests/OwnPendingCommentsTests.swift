import FeeqdCore
import XCTest

/// A comment the board holds for the team stays in its author's thread, marked as waiting,
/// after the thread is read again: the public thread never returns it, so the store also asks
/// go-gatherer for this device's held comments (`…/my-pending-comments`) and adds them.
@MainActor
final class OwnPendingCommentsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    /// The public thread from the fixture, and `pending` for the held-comments route.
    private func answer(pending: StubURLProtocol.Response) throws {
        let page = try Fixture.data("comments_page")
        StubURLProtocol.responder = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/my-pending-comments") { return pending }
            if path.hasSuffix("/comments") { return .json(200, page) }
            return .init(status: 404)
        }
    }

    private func pendingRequest() -> URLRequest? {
        StubURLProtocol.requests.first { $0.url?.path.hasSuffix("/my-pending-comments") == true }
    }

    func testTheHeldCommentsDecodeAsWaitingForTheTeam() throws {
        let held = try FeeqdClient.decodePendingComments(Fixture.data("my_pending_comments"))
        XCTAssertEqual(held.map(\.content), ["Waiting for the team.", "A held reply."])
        XCTAssertEqual(held.map(\.isPendingModeration), [true, true])
        XCTAssertEqual(held.last?.parentID, "0003BNsEz27agPfFB1g3nzv0JPe")
        XCTAssertEqual(held.first?.createdAt, FeeqdDate.parse("2026-11-11T14:40:02"))
    }

    /// A state that is not `pending` is not one to show as waiting: published, the thread has
    /// it; rejected, nothing is shown.
    func testOnlyWhatIsStillWaitingIsKept() throws {
        let json = """
        {"items":[
          {"id":"a","content":"held","moderation_state":"pending","created_at":"2026-11-11T14:40:02"},
          {"id":"b","content":"out","moderation_state":"published","created_at":"2026-11-11T14:40:02"},
          {"id":"c","content":"no","moderation_state":"rejected","created_at":"2026-11-11T14:40:02"},
          {"broken":true}
        ]}
        """
        XCTAssertEqual(try FeeqdClient.decodePendingComments(Data(json.utf8)).map(\.id), ["a"])
    }

    func testTheAuthorsHeldCommentsAreInTheThreadMarkedPending() async throws {
        try answer(pending: .json(200, Fixture.data("my_pending_comments")))
        let store = CommentsStore(client: .stubbed(deviceID: "dev_author"), boardID: "B", entryID: "E")
        await store.load()

        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.threads.map(\.root.content), ["Yes please, my eyes hurt.", "Waiting for the team."])
        XCTAssertEqual(store.threads.map(\.root.isPendingModeration), [false, true])
        XCTAssertEqual(store.threads.first?.replies.map(\.content), ["Same here.", "A held reply."])
        XCTAssertEqual(store.threads.first?.replies.map(\.isPendingModeration), [false, true])

        let request = try XCTUnwrap(pendingRequest())
        XCTAssertEqual(request.url?.host, "gatherer.test")
        XCTAssertEqual(request.url?.path, "/sdk/boards/B/entries/E/my-pending-comments")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Feeqd-Key"), "feeqd_pk_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Feeqd-Device-Id"), "dev_author")
    }

    /// The team approved it between the two reads: the thread's copy, a normal comment, is
    /// the only one shown.
    func testAHeldCommentTheThreadAlreadyHasShowsOnceAsPublished() async throws {
        let json = """
        {"items":[{"id":"0003BNsEz27agPfFB1g3nzv0JPe","parent_id":null,"content":"Yes please, my eyes hurt.",
                   "moderation_state":"pending","created_at":"2026-09-11T07:18:14"}]}
        """
        try answer(pending: .json(200, Data(json.utf8)))
        let store = CommentsStore(client: .stubbed(), boardID: "B", entryID: "E")
        await store.load()

        XCTAssertEqual(store.comments.count, 2)
        XCTAssertEqual(store.threads.count, 1)
        XCTAssertEqual(store.threads.first?.root.isPendingModeration, false)
    }

    /// A backend from before the route: the thread reads exactly as it did.
    func testABackendWithoutTheRouteChangesNothing() async throws {
        try answer(pending: .json(404, Fixture.data("error_unknown_endpoint")))
        let store = CommentsStore(client: .stubbed(), boardID: "B", entryID: "E")
        await store.load()

        XCTAssertEqual(store.phase, .loaded)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.comments.map(\.content), ["Yes please, my eyes hurt.", "Same here."])
        XCTAssertFalse(store.comments.contains(where: \.isPendingModeration))
        XCTAssertNotNil(pendingRequest(), "asked once, and the 404 taken as nothing held")
    }

    /// Nothing held: the thread is the thread.
    func testNothingHeldAddsNothing() async throws {
        try answer(pending: .json(200, Data(#"{"board_id":"B","entry_id":"E","items":[]}"#.utf8)))
        let store = CommentsStore(client: .stubbed(), boardID: "B", entryID: "E")
        await store.load()
        XCTAssertEqual(store.comments.map(\.content), ["Yes please, my eyes hurt.", "Same here."])
    }

    /// A request still in review reads its thread through the author's route: held comments
    /// join that one too.
    func testHeldCommentsJoinTheThreadOfARequestInReview() async throws {
        try answer(pending: .json(200, Fixture.data("my_pending_comments")))
        let store = CommentsStore(client: .stubbed(), boardID: "B", entryID: "E")
        await store.load(ownInReview: true)

        XCTAssertTrue(StubURLProtocol.requests.contains { $0.url?.path == "/sdk/boards/B/mine/E/comments" })
        XCTAssertEqual(store.comments.filter(\.isPendingModeration).map(\.content), ["Waiting for the team.", "A held reply."])
    }
}

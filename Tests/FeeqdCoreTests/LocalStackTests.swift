import FeeqdCore
import XCTest

/// The whole client against a real Feeqd stack, not stubs.
///
/// Skipped unless `FEEQD_LOCAL_KEY` and `FEEQD_LOCAL_BOARD` are set. The board must accept
/// anonymous submissions (`allow_anonymous_widget`) and hold at least one entry. Optional:
/// `FEEQD_READER_URL` (default `http://localhost:8093`), `FEEQD_GATHERER_URL` (`:8092`).
final class LocalStackTests: XCTestCase {
    private var client: FeeqdClient!
    private var boardID = ""

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["FEEQD_LOCAL_KEY"], let board = env["FEEQD_LOCAL_BOARD"] else {
            throw XCTSkip("Set FEEQD_LOCAL_KEY and FEEQD_LOCAL_BOARD to run against a local stack")
        }
        boardID = board
        client = FeeqdClient(
            configuration: ClientConfiguration(
                apiKey: key,
                readerURL: URL(string: env["FEEQD_READER_URL"] ?? "http://localhost:8093")!,
                gathererURL: URL(string: env["FEEQD_GATHERER_URL"] ?? "http://localhost:8092")!,
                appVersion: "9.9.9"
            ),
            identity: DeviceIdentity(store: InMemorySecretStore())
        )
    }

    func testTheWholeClientAgainstTheStack() async throws {
        let config = try await client.config()
        XCTAssertEqual(config.boardID, boardID)
        XCTAssertFalse(config.statuses.isEmpty, "the config carries the board's statuses")
        let again = try await client.config()
        XCTAssertEqual(config, again, "the second call revalidates with the ETag")

        let page = try await client.entries(boardID: boardID, page: 1, pageSize: 20, sort: config.behaviour.defaultSort)
        let entry = try XCTUnwrap(page.items.first, "the board needs at least one entry")
        let detail = try await client.entry(boardID: boardID, entryID: entry.id)
        XCTAssertEqual(detail.title, entry.title)

        let before = try await client.myVotes(boardID: boardID)
        XCTAssertFalse(before.contains(entry.id))

        let cast = try await client.vote(boardID: boardID, entryID: entry.id)
        XCTAssertTrue(cast.voted)
        XCTAssertEqual(cast.voteCount, entry.voteCount + 1)
        let mine = try await client.myVotes(boardID: boardID)
        XCTAssertTrue(mine.contains(entry.id))
        let retracted = try await client.retractVote(boardID: boardID, entryID: entry.id)
        XCTAssertFalse(retracted.voted)
        XCTAssertEqual(retracted.voteCount, entry.voteCount)

        let root = try await client.comment(boardID: boardID, entryID: entry.id, content: "From the SDK test")
        let reply = try await client.comment(boardID: boardID, entryID: entry.id, content: "A reply", parentID: root.id)
        XCTAssertFalse(reply.id.isEmpty)
        let comments = try await client.comments(boardID: boardID, entryID: entry.id, page: 1, pageSize: 50)
        XCTAssertTrue(comments.items.contains { $0.id == root.id })
        XCTAssertEqual(comments.items.first { $0.id == reply.id }?.parentID, root.id)

        let receipt = try await client.submit(boardID: boardID, title: "Sent by FeeqdKit", description: "integration test")
        XCTAssertEqual(receipt.status, "queued")

        _ = try await client.similar(boardID: boardID, title: "dark mode")
    }

    @MainActor
    func testTheBoardStoreColdStart() async throws {
        let store = BoardStore(client: client)
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.boardID, boardID)
        XCTAssertFalse(store.entries.isEmpty)
    }
}

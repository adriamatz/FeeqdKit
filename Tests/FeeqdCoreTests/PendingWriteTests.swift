@testable import FeeqdCore
import Foundation
import XCTest

/// A comment, a request or a chat message that could not go out is kept and sent later with the
/// key it was first sent with, so a server that already stored it answers with what it stored.
@MainActor
final class PendingWriteTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private let created = Data(#"{"id":"c1","entry_id":"E","content":"Hi"}"#.utf8)

    private func answer(_ responses: StubURLProtocol.Response...) {
        StubURLProtocol.responder = { _ in responses[min(StubURLProtocol.requests.count, responses.count) - 1] }
    }

    private func key(_ request: URLRequest) -> String? { request.value(forHTTPHeaderField: "Idempotency-Key") }

    // MARK: Keys

    func testAWriteKeepsOneIdempotencyKeyAcrossItsRetries() async throws {
        answer(.init(status: 503), .json(201, created))
        _ = try await FeeqdClient.stubbed().comment(boardID: "B", entryID: "E", content: "Hi")
        let keys = StubURLProtocol.requests.map(key)
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotNil(keys[0])
        XCTAssertEqual(keys[0], keys[1])
    }

    func testAWriteStillRunningOnTheServerIsWaitedOut() async throws {
        answer(.json(409, Data(#"{"error":"idempotency_in_progress"}"#.utf8)), .json(201, created))
        _ = try await FeeqdClient.stubbed().comment(boardID: "B", entryID: "E", content: "Hi")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    // MARK: What is kept

    func testOnlyAWriteThatCanGoOutLaterIsKept() async throws {
        let client = FeeqdClient.stubbed()
        let offline = await client.canKeepForLater(.offline)
        let gateway = await client.canKeepForLater(.server(status: 503, code: nil, message: nil))
        let timeout = await client.canKeepForLater(.transport("timed out"))
        let serverError = await client.canKeepForLater(.server(status: 500, code: nil, message: nil))
        let refused = await client.canKeepForLater(.server(status: 400, code: "validation_error", message: nil))
        let full = await client.canKeepForLater(.quotaExceeded)
        XCTAssertTrue(offline)
        XCTAssertTrue(gateway)
        XCTAssertTrue(timeout, "it goes again with its key, and the server keeps one")
        XCTAssertTrue(serverError)
        XCTAssertFalse(refused)
        XCTAssertFalse(full)
    }

    // MARK: Sending later

    func testAKeptCommentGoesOutWithItsFirstKey() async throws {
        let client = FeeqdClient.stubbed()
        await client.keepForLater(PendingWrite(id: "K1", kind: .comment(boardID: "B", entryID: "E", content: "Hi", parentID: nil)))
        answer(.json(201, created))
        await client.sendPendingWrites()

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/sdk/boards/B/entries/E/comments")
        XCTAssertEqual(key(request), "K1")
        let left = await client.pendingWrites()
        XCTAssertEqual(left, [])
    }

    func testAKeptWriteStaysWhileStillOffline() async throws {
        let client = FeeqdClient.stubbed()
        await client.keepForLater(PendingWrite(id: "K1", kind: .request(boardID: "B", title: "Dark mode", description: "")))
        await client.keepForLater(PendingWrite(id: "K2", kind: .comment(boardID: "B", entryID: "E", content: "Hi", parentID: nil)))
        answer(.failure(.notConnectedToInternet))
        await client.sendPendingWrites()

        let left = await client.pendingWrites()
        XCTAssertEqual(left.map(\.id), ["K1", "K2"])
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.url?.path == "/sdk/boards/B/entries" }, "stops at the first that can't go out")
    }

    func testAKeptWriteTheServerRefusesIsDropped() async throws {
        let client = FeeqdClient.stubbed()
        await client.keepForLater(PendingWrite(id: "K1", kind: .comment(boardID: "B", entryID: "E", content: "Hi", parentID: nil)))
        answer(.json(404, Data(#"{"error":"entry_not_found"}"#.utf8)))
        await client.sendPendingWrites()
        let left = await client.pendingWrites()
        XCTAssertEqual(left, [])
    }

    func testAWriteKeptTooLongIsDroppedUnsent() async throws {
        let client = FeeqdClient.stubbed()
        let old = Date().addingTimeInterval(-8 * 24 * 3600)
        await client.keepForLater(PendingWrite(id: "K1", kind: .chatMessage(body: "Hi"), createdAt: old))
        answer(.json(201, created))
        await client.sendPendingWrites()
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
        let left = await client.pendingWrites()
        XCTAssertEqual(left, [])
    }

    func testAKeptChatMessageGoesToTheOpenConversation() async throws {
        let client = FeeqdClient.stubbed()
        await client.keepForLater(PendingWrite(id: "K1", kind: .chatMessage(body: "Still crashing")))
        let conversations = try Fixture.data("chat_conversations")
        let sent = try Fixture.data("chat_message_created")
        StubURLProtocol.responder = { request in
            request.httpMethod == "GET" ? .json(200, conversations) : .json(201, sent)
        }
        await client.sendPendingWrites()

        let post = try XCTUnwrap(StubURLProtocol.requests.first { $0.httpMethod == "POST" })
        XCTAssertEqual(post.url?.path, "/sdk/chat/conversations/0003CHATopen00000000000002/messages")
        XCTAssertEqual(key(post), "K1")
        let left = await client.pendingWrites()
        XCTAssertEqual(left, [])
    }

    func testResetForgetsThePreviousUsersPendingWrites() async throws {
        let client = FeeqdClient.stubbed()
        await client.keepForLater(PendingWrite(id: "K1", kind: .chatMessage(body: "Hi")))
        await client.reset()
        let left = await client.pendingWrites()
        XCTAssertEqual(left, [])
    }

    func testPendingWritesOutliveTheApp() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("feeqd-outbox-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let write = PendingWrite(id: "K1", kind: .comment(boardID: "B", entryID: "E", content: "Hi", parentID: "P"))
        await Outbox(fileURL: file).add(write)
        let reopened = await Outbox(fileURL: file).all()
        XCTAssertEqual(reopened, [write])
    }

    // MARK: Screens

    func testACommentThatCannotGoOutShowsAsNotSentYet() async throws {
        answer(.failure(.notConnectedToInternet))
        let store = CommentsStore(client: .stubbed(), boardID: "B", entryID: "E")
        let cleared = await store.send(content: "Hi")

        XCTAssertTrue(cleared, "the draft is cleared: it is kept, and sending it again would post it twice")
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.threads.map(\.root.content), ["Hi"])
        XCTAssertEqual(store.threads.first?.root.isPendingSend, true)
    }

    func testAChatMessageThatCannotGoOutShowsAsNotSentYet() async throws {
        answer(.failure(.notConnectedToInternet))
        let store = ChatStore(client: .stubbed())
        let cleared = await store.send("Still crashing")

        XCTAssertTrue(cleared)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.visibleMessages.map(\.body), ["Still crashing"])
        XCTAssertEqual(store.visibleMessages.first?.isPendingSend, true)
        XCTAssertTrue(store.messages.isEmpty, "never in the list the next poll asks the server to continue from")
    }

    func testARequestThatCannotGoOutIsKept() async throws {
        let config = try Fixture.data("sdk_config")
        StubURLProtocol.responder = { request in
            request.url?.path == "/sdk/config" ? .json(200, config) : .failure(.notConnectedToInternet)
        }
        let client = FeeqdClient.stubbed()
        let store = BoardStore(client: client)
        await store.load()
        let receipt = try await store.submit(title: "Dark mode", description: "")

        XCTAssertNil(receipt, "kept for later, not sent")
        let left = await client.pendingWrites()
        XCTAssertEqual(left.count, 1)
    }

    func testARefusedCommentIsStillAnError() async throws {
        answer(.json(400, Data(#"{"error":"invalid_parent"}"#.utf8)))
        let store = CommentsStore(client: .stubbed(), boardID: "B", entryID: "E")
        let cleared = await store.send(content: "Hi", parentID: "R")
        XCTAssertFalse(cleared)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.threads.isEmpty)
    }
}

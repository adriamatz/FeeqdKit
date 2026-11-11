import FeeqdCore
import XCTest

/// Where the app opened the chat from goes with the first message of each visit, and the
/// device's model, OS, locale and app version with it: that is what the dashboard shows beside
/// the conversation. Not on every message, and nothing at all when the app gave no context.
@MainActor
final class ChatContextTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private let club = ["view": "club", "club": "Fae & Fury", "channel": "General"]

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func context(_ request: URLRequest) throws -> [String: Any]? {
        try body(request)["context"] as? [String: Any]
    }

    private var posts: [URLRequest] {
        StubURLProtocol.requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/read") == false }
    }

    private func route(conversations: Data, onStart: Data? = nil) throws {
        let messages = try Fixture.data("chat_messages")
        let created = try Fixture.data("chat_message_created")
        StubURLProtocol.responder = { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod, path) {
            case ("GET", "/sdk/chat/conversations"): return .json(200, conversations)
            case ("GET", _) where path.hasSuffix("/messages"): return .json(200, messages)
            case ("POST", "/sdk/chat/conversations"): return .json(201, onStart ?? Data("{}".utf8))
            case ("POST", _) where path.hasSuffix("/messages"): return .json(201, created)
            case ("POST", _) where path.hasSuffix("/read"): return .init(status: 204)
            default: return .init(status: 404)
            }
        }
    }

    // MARK: Client

    func testTheAppsKeysGoAsTheyCameWithTheDeviceBesideThem() async throws {
        StubURLProtocol.responder = { _ in .json(201, try! Fixture.data("chat_conversation_created")) }
        _ = try await FeeqdClient.stubbed().startConversation(message: "Hi", context: club)

        let sent = try XCTUnwrap(context(XCTUnwrap(StubURLProtocol.requests.first)))
        XCTAssertEqual(sent["view"] as? String, "club")
        XCTAssertEqual(sent["club"] as? String, "Fae & Fury")
        XCTAssertEqual(sent["channel"] as? String, "General")
        let device = try XCTUnwrap(sent["device"] as? [String: String])
        XCTAssertNotNil(device["model"])
        XCTAssertNotNil(device["os"])
        XCTAssertNotNil(device["locale"])
        XCTAssertEqual(device["language"], Locale.preferredLanguages.first, "what the SDK's texts show in")
        XCTAssertEqual(device["sdk"], FeeqdCoreVersion.current)
    }

    func testTheAppCannotPassItsOwnDevice() async throws {
        StubURLProtocol.responder = { _ in .json(201, try! Fixture.data("chat_message_created")) }
        _ = try await FeeqdClient.stubbed().sendChatMessage(conversationID: "C", body: "Hi", context: ["device": "fake"])

        let sent = try XCTUnwrap(context(XCTUnwrap(StubURLProtocol.requests.first)))
        XCTAssertNotNil(sent["device"] as? [String: String], "the device's own fields win")
    }

    func testNoContextSendsNoContext() async throws {
        StubURLProtocol.responder = { _ in .json(201, try! Fixture.data("chat_message_created")) }
        _ = try await FeeqdClient.stubbed().sendChatMessage(conversationID: "C", body: "Hi")

        XCTAssertNil(try body(XCTUnwrap(StubURLProtocol.requests.first))["context"])
    }

    // MARK: Store

    func testAFirstConversationIsOpenedWithTheContextAndTheNextMessageGoesWithout() async throws {
        try route(conversations: Data(#"{"items":[]}"#.utf8), onStart: Fixture.data("chat_conversation_created"))
        let store = ChatStore(client: .stubbed(), context: club)
        await store.load()

        _ = await store.send("The chat freezes")
        _ = await store.send("On the iPad")

        XCTAssertEqual(posts.map(\.url?.path), ["/sdk/chat/conversations", "/sdk/chat/conversations/0003CHATnew000000000000003/messages"])
        XCTAssertEqual(try context(posts[0])?["club"] as? String, "Fae & Fury")
        XCTAssertNil(try context(posts[1]), "one visit, one context")
    }

    func testAnOldConversationGetsTheContextOnTheFirstMessageOfTheVisit() async throws {
        try route(conversations: Fixture.data("chat_conversations"))
        let store = ChatStore(client: .stubbed(), context: club)
        await store.load()

        _ = await store.send("Still broken")
        _ = await store.send("Since this morning")

        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(try context(posts[0])?["channel"] as? String, "General")
        XCTAssertNil(try context(posts[1]))
    }

    func testAnOpenConversationTheScreenDidNotKnowGetsTheContextWithTheMessage() async throws {
        // `200` with no `first_message_id`: the device had one open, which keeps the context it
        // was opened with. The message that goes in separately carries this visit's.
        let existing = Data(#"{"id":"0003CHATopen00000000000002","status":"open","created_at":"2026-09-27T10:00:00"}"#.utf8)
        try route(conversations: Data(#"{"items":[]}"#.utf8), onStart: existing)
        let store = ChatStore(client: .stubbed(), context: club)
        await store.load()

        _ = await store.send("Hello")

        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(try context(posts[1])?["view"] as? String, "club")
    }

    func testAVisitWithANewScreenSendsItAgain() async throws {
        try route(conversations: Fixture.data("chat_conversations"))
        let client = FeeqdClient.stubbed()
        let first = ChatStore(client: client, context: club)
        await first.load()
        _ = await first.send("From the club")
        let second = ChatStore(client: client, context: ["view": "directory"])
        await second.load()
        _ = await second.send("From the directory")

        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(try context(posts[1])?["view"] as? String, "directory")
    }

    func testAnEmptyContextIsNoContext() async throws {
        try route(conversations: Fixture.data("chat_conversations"))
        let store = ChatStore(client: .stubbed(), context: [:])
        await store.load()
        _ = await store.send("Hi")

        XCTAssertNil(try context(XCTUnwrap(posts.first)))
    }

    // MARK: Kept for later

    func testAFirstMessageKeptForLaterKeepsTheContext() async throws {
        let conversations = try Fixture.data("chat_conversations")
        let messages = try Fixture.data("chat_messages")
        StubURLProtocol.responder = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET" { return path.hasSuffix("/messages") ? .json(200, messages) : .json(200, conversations) }
            if path.hasSuffix("/read") { return .init(status: 204) }
            return .failure(.notConnectedToInternet)
        }
        let client = FeeqdClient.stubbed()
        let store = ChatStore(client: client, context: club)
        await store.load()
        _ = await store.send("Offline")
        _ = await store.send("Still offline")

        let kept = await client.pendingWrites().map(\.kind)
        XCTAssertEqual(kept, [
            .chatMessage(body: "Offline", conversationID: "0003CHATopen00000000000002", context: club),
            .chatMessage(body: "Still offline", conversationID: "0003CHATopen00000000000002", context: nil),
        ])

        StubURLProtocol.reset()
        StubURLProtocol.responder = { _ in .json(201, try! Fixture.data("chat_message_created")) }
        await client.sendPendingWrites()
        XCTAssertEqual(try context(XCTUnwrap(StubURLProtocol.requests.first))?["club"] as? String, "Fae & Fury")
        XCTAssertNotNil(try context(XCTUnwrap(StubURLProtocol.requests.first))?["device"], "read again when it goes out")
        XCTAssertNil(try context(StubURLProtocol.requests[1]))
    }

    func testAMessageKeptByTheLastVersionHasNoContext() throws {
        let old = Data(#"[{"id":"K1","kind":{"chatMessage":{"body":"Hi","conversationID":"C"}},"createdAt":0}]"#.utf8)
        let writes = try JSONDecoder().decode([PendingWrite].self, from: old)
        XCTAssertEqual(writes.first?.kind, .chatMessage(body: "Hi", conversationID: "C", context: nil))
    }
}

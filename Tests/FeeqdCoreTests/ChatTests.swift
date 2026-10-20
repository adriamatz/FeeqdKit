import FeeqdCore
import XCTest

@MainActor
final class ChatTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: String] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    // MARK: Client

    func testReadsGoToTheReaderWithKeyAndDevice() async throws {
        let body = try Fixture.data("chat_conversations")
        StubURLProtocol.responder = { _ in .json(200, body) }
        let conversations = try await FeeqdClient.stubbed(deviceID: "dev_abc").chatConversations()

        XCTAssertEqual(conversations.map(\.status), [.open, .closed])
        XCTAssertEqual(conversations.first?.unreadCount, 1)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://reader.test/sdk/chat/conversations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Feeqd-Key"), "feeqd_pk_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Feeqd-Device-Id"), "dev_abc")
    }

    func testMessagesAskOnlyForWhatCameAfterTheLastOne() async throws {
        let body = try Fixture.data("chat_messages")
        StubURLProtocol.responder = { _ in .json(200, body) }
        _ = try await FeeqdClient.stubbed().chatMessages(conversationID: "C", sinceID: "M9")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://reader.test/sdk/chat/conversations/C/messages?since=M9")
    }

    func testWritesGoToTheGathererAsUserActions() async throws {
        let created = try Fixture.data("chat_conversation_created")
        let message = try Fixture.data("chat_message_created")
        StubURLProtocol.responder = { request in
            request.url?.path == "/sdk/chat/conversations" ? .json(201, created) : .json(201, message)
        }
        let client = FeeqdClient.stubbed()
        let started = try await client.startConversation(message: "Hi")
        let sent = try await client.sendChatMessage(conversationID: "C", body: "More")

        XCTAssertEqual(started.firstMessageID, "0003MSGf000000000000000006")
        XCTAssertEqual(sent.sender, .device)
        let (start, send) = (StubURLProtocol.requests[0], StubURLProtocol.requests[1])
        XCTAssertEqual(start.url?.absoluteString, "http://gatherer.test/sdk/chat/conversations")
        XCTAssertEqual(try jsonBody(start), ["message": "Hi"])
        XCTAssertEqual(send.url?.absoluteString, "http://gatherer.test/sdk/chat/conversations/C/messages")
        XCTAssertEqual(try jsonBody(send), ["body": "More"])
        XCTAssertNotNil(send.value(forHTTPHeaderField: "X-Feeqd-Device-Info"), "writing to the team is something the user did")
    }

    func testMarkReadSendsTheLastIDAndNoDiagnostics() async throws {
        StubURLProtocol.responder = { _ in .init(status: 204) }
        try await FeeqdClient.stubbed().markChatRead(conversationID: "C", lastReadID: "M3")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://gatherer.test/sdk/chat/conversations/C/read")
        XCTAssertEqual(try jsonBody(request), ["last_read_id": "M3"])
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Feeqd-Device-Info"))
    }

    func testChatErrorsMapToTheirOwnCases() {
        func error(_ status: Int, _ code: String) -> FeeqdError {
            FeeqdError.from(status: status, data: Data(#"{"error":"\#(code)"}"#.utf8), retryAfter: nil)
        }
        XCTAssertEqual(error(429, "quota_exceeded"), .quotaExceeded)
        XCTAssertEqual(error(409, "conversation_closed"), .conversationClosed)
        XCTAssertEqual(error(409, "another_conversation_open"), .conversationClosed)
        XCTAssertEqual(error(403, "insufficient_scope"), .insufficientScope)
        XCTAssertEqual(error(429, "rate_limited"), .rateLimited(retryAfter: nil), "a plain 429 is still a rate limit")
    }

    // MARK: Decoding

    func testUnknownValuesNeverDrawSomeoneElseAsTheUser() throws {
        let data = Data(#"{"items":[{"id":"M1","sender":"bot","kind":"text","body":"Hi"}],"status":"archived"}"#.utf8)
        let list = try JSONDecoder.feeqd.decode(ChatMessageList.self, from: data)

        XCTAssertEqual(list.items.first?.sender, .team, "an unknown sender reads as the team, never as the user")
        XCTAssertEqual(list.status, .closed, "an unknown status reads as closed: no writing into it")
    }

    // MARK: Store

    private func routeChat(conversations: Data, sendStatus: Int = 201, onStart: Data? = nil) throws {
        let messages = try Fixture.data("chat_messages")
        let created = try Fixture.data("chat_message_created")
        StubURLProtocol.responder = { request in
            let path = request.url?.path ?? ""
            switch (request.httpMethod, path) {
            case ("GET", "/sdk/chat/conversations"): return .json(200, conversations)
            case ("GET", _) where path.hasSuffix("/messages"): return .json(200, messages)
            case ("POST", "/sdk/chat/conversations"): return .json(201, onStart ?? Data("{}".utf8))
            case ("POST", _) where path.hasSuffix("/messages"):
                return sendStatus == 201 ? .json(201, created) : .json(sendStatus, Data(#"{"error":"conversation_closed"}"#.utf8))
            case ("POST", _) where path.hasSuffix("/read"): return .init(status: 204)
            default: return .init(status: 404)
            }
        }
    }

    func testLoadShowsTheOpenConversationAndMarksTheTeamReplyRead() async throws {
        try routeChat(conversations: Fixture.data("chat_conversations"))
        let store = ChatStore(client: .stubbed())
        await store.load()

        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.conversation?.id, "0003CHATopen00000000000002", "the open one wins over the older closed one")
        XCTAssertEqual(store.visibleMessages.map(\.body), ["The export crashes", "Thanks, we're on it"], "no system rows")
        let read = try XCTUnwrap(StubURLProtocol.requests.first { $0.url?.path.hasSuffix("/read") == true })
        XCTAssertEqual(try jsonBody(read), ["last_read_id": "0003MSGc000000000000000003"])
    }

    func testAFailedLoadIsAnErrorNotAnEmptyChat() async throws {
        StubURLProtocol.responder = { _ in .init(status: 503) }
        let store = ChatStore(client: .stubbed())
        await store.load()

        guard case .failed = store.phase else { return XCTFail("expected a failure, got \(store.phase)") }
        XCTAssertNil(store.conversation)
    }

    func testFirstMessageOpensAConversation() async throws {
        try routeChat(conversations: Data(#"{"items":[]}"#.utf8), onStart: Fixture.data("chat_conversation_created"))
        let store = ChatStore(client: .stubbed())
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertNil(store.conversation)

        let sent = await store.send("  The export crashes  ")

        XCTAssertTrue(sent)
        XCTAssertEqual(store.conversation?.id, "0003CHATnew000000000000003")
        let start = try XCTUnwrap(StubURLProtocol.requests.first { $0.httpMethod == "POST" && $0.url?.path == "/sdk/chat/conversations" })
        XCTAssertEqual(try jsonBody(start), ["message": "The export crashes"], "trimmed, and sent once")
        XCTAssertFalse(
            StubURLProtocol.requests.contains { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/messages") == true },
            "the server stored it with the conversation"
        )
    }

    func testAnAlreadyOpenConversationGetsTheMessageSeparately() async throws {
        // `200` with no `first_message_id`: the device had one open, and the text was not stored.
        let existing = Data(#"{"id":"0003CHATopen00000000000002","status":"open","created_at":"2026-09-27T10:00:00"}"#.utf8)
        try routeChat(conversations: Data(#"{"items":[]}"#.utf8), onStart: existing)
        let store = ChatStore(client: .stubbed())
        await store.load()

        _ = await store.send("Hello")

        let send = try XCTUnwrap(StubURLProtocol.requests.first { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/messages") == true })
        XCTAssertEqual(send.url?.path, "/sdk/chat/conversations/0003CHATopen00000000000002/messages")
    }

    func testWritingIntoAConversationTheTeamJustClosedStartsANewOne() async throws {
        try routeChat(
            conversations: Fixture.data("chat_conversations"), sendStatus: 409, onStart: Fixture.data("chat_conversation_created")
        )
        let store = ChatStore(client: .stubbed())
        await store.load()

        let sent = await store.send("Still broken")

        XCTAssertTrue(sent)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.conversation?.id, "0003CHATnew000000000000003")
    }

    func testTooLongIsRefusedBeforeTheNetwork() async throws {
        try routeChat(conversations: Fixture.data("chat_conversations"))
        let store = ChatStore(client: .stubbed())
        await store.load()
        let before = StubURLProtocol.requests.count

        // 2,001 × "é" (2 bytes each): under 4,000 characters, over 4,000 bytes.
        let sent = await store.send(String(repeating: "é", count: 2001))

        XCTAssertFalse(sent)
        XCTAssertEqual(StubURLProtocol.requests.count, before)
        XCTAssertEqual(store.lastError, .server(status: 422, code: "message_too_long", message: nil))
    }

    func testStatusFailsClosed() async throws {
        StubURLProtocol.responder = { _ in .json(403, Data(#"{"detail":"API key lacks the chat scope"}"#.utf8)) }
        let denied = await ChatStatus.check(.stubbed())
        XCTAssertEqual(denied, .unavailable)

        try routeChat(conversations: Fixture.data("chat_conversations"))
        let allowed = await ChatStatus.check(.stubbed())
        XCTAssertEqual(allowed, ChatStatus(available: true, hasUnread: true))
    }

    /// With the team's conversations quota used up, only someone already talking keeps the chat.
    func testStatusWithoutRoomForNewConversations() async throws {
        try routeChat(conversations: Fixture.data("chat_conversations"))
        let talking = await ChatStatus.check(.stubbed(), acceptingNew: false)
        XCTAssertEqual(talking, ChatStatus(available: true, hasUnread: true), "an open conversation goes on")

        try routeChat(conversations: Data(#"{"items":[{"id":"C1","status":"closed","unread_count":0,"created_at":"2026-09-20T08:00:00"}]}"#.utf8))
        let closedOnly = await ChatStatus.check(.stubbed(), acceptingNew: false)
        XCTAssertEqual(closedOnly, .unavailable, "no new chat to offer")
    }
}

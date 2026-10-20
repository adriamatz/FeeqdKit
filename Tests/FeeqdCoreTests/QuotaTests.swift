import FeeqdCore
import XCTest

/// The two 429s go-gatherer answers: `quota_exceeded` (the plan is full: never retried, and the
/// app stops offering it) and `rate_limited` (too fast: waited out once when the wait is short).
final class QuotaTests: XCTestCase {
    override func setUp() {
        StubURLProtocol.reset()
    }

    private let quotaFull = Data(#"{"error":"quota_exceeded","message":"This app is not accepting new requests"}"#.utf8)

    /// `/sdk/config` answers 304 to a revalidation, 200 with `fresh` otherwise.
    private func config(_ fresh: String = #"{"accepting_entries": true, "accepting_conversations": true}"#) -> (URLRequest) -> StubURLProtocol.Response? {
        { request in
            guard request.url?.path == "/sdk/config" else { return nil }
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" { return .init(status: 304, headers: ["ETag": "\"v1\""]) }
            return .json(200, Data(fresh.utf8), headers: ["ETag": "\"v1\""])
        }
    }

    private func count(_ path: String) -> Int {
        StubURLProtocol.requests.filter { $0.url?.path == path }.count
    }

    func testAFullPlanOnSubmitIsNotRetriedAndClosesSubmitting() async throws {
        let config = config()
        StubURLProtocol.responder = { request in
            config(request) ?? .json(429, self.quotaFull)
        }
        let client = FeeqdClient.stubbed()
        let before = try await client.config()
        XCTAssertTrue(before.acceptingEntries)

        do {
            _ = try await client.submit(boardID: "B1", title: "Dark mode", description: "")
            XCTFail("a full plan must throw")
        } catch {
            XCTAssertEqual(error as? FeeqdError, .quotaExceeded)
        }
        XCTAssertEqual(count("/sdk/boards/B1/entries"), 1, "quota_exceeded is never retried")
        XCTAssertEqual(count("/public/comment/B1"), 0, "nor sent down the old route")

        let after = try await client.config()
        XCTAssertFalse(after.acceptingEntries, "the cached config (a 304) is marked full locally")
        XCTAssertTrue(after.acceptingConversations, "the chat is another quota")
    }

    func testAFreshConfigFromTheServerWinsOverTheLocalMark() async throws {
        var fresh = false
        StubURLProtocol.responder = { request in
            if request.url?.path == "/sdk/config" {
                if !fresh, request.value(forHTTPHeaderField: "If-None-Match") != nil { return .init(status: 304) }
                return .json(200, Data(#"{"accepting_entries": true}"#.utf8), headers: ["ETag": fresh ? "\"v2\"" : "\"v1\""])
            }
            return .json(429, self.quotaFull)
        }
        let client = FeeqdClient.stubbed()
        _ = try await client.config()
        _ = try? await client.submit(boardID: "B1", title: "Dark mode", description: "")
        let marked = try await client.config()
        XCTAssertFalse(marked.acceptingEntries)

        fresh = true
        let refreshed = try await client.config()
        XCTAssertTrue(refreshed.acceptingEntries, "the team upgraded: the server's answer is the truth again")
    }

    func testAFullPlanOnANewChatClosesNewChats() async throws {
        let config = config()
        StubURLProtocol.responder = { request in
            config(request) ?? .json(429, Data(#"{"error":"quota_exceeded"}"#.utf8))
        }
        let client = FeeqdClient.stubbed()
        _ = try await client.config()

        do {
            _ = try await client.startConversation(message: "Hola")
            XCTFail("a full plan must throw")
        } catch {
            XCTAssertEqual(error as? FeeqdError, .quotaExceeded)
        }
        XCTAssertEqual(count("/sdk/chat/conversations"), 1, "quota_exceeded is never retried")

        let after = try await client.config()
        XCTAssertFalse(after.acceptingConversations)
        XCTAssertTrue(after.acceptingEntries)
    }

    func testAShortRateLimitIsWaitedOutOnce() async throws {
        var calls = 0
        StubURLProtocol.responder = { _ in
            calls += 1
            // The wait only in the body, as go-gatherer also sends it.
            return calls == 1
                ? .json(429, Data(#"{"error":"rate_limited","message":"Too many requests","retry_after":0}"#.utf8))
                : .json(202, try! Fixture.data("submit_accepted"))
        }
        let receipt = try await FeeqdClient.stubbed().submit(boardID: "B1", title: "Dark mode", description: "")
        XCTAssertEqual(receipt.status, try Fixture.decode(SubmitReceipt.self, "submit_accepted").status)
        XCTAssertEqual(count("/sdk/boards/B1/entries"), 2, "sent once more after the wait")
    }

    func testARateLimitIsRetriedOnlyOnce() async throws {
        StubURLProtocol.responder = { _ in
            .json(429, Data(#"{"error":"rate_limited","retry_after":0}"#.utf8), headers: ["Retry-After": "0"])
        }
        do {
            _ = try await FeeqdClient.stubbed().submit(boardID: "B1", title: "Dark mode", description: "")
            XCTFail("still limited after the retry")
        } catch {
            XCTAssertEqual(error as? FeeqdError, .rateLimited(retryAfter: 0))
        }
        XCTAssertEqual(count("/sdk/boards/B1/entries"), 2)
    }

    func testALongRateLimitIsLeftToTheUser() async throws {
        StubURLProtocol.responder = { _ in
            .json(429, Data(#"{"error":"rate_limited","retry_after":60}"#.utf8), headers: ["Retry-After": "60"])
        }
        do {
            _ = try await FeeqdClient.stubbed().startConversation(message: "Hola")
            XCTFail("a minute is too long to hold the user")
        } catch {
            XCTAssertEqual(error as? FeeqdError, .rateLimited(retryAfter: 60))
        }
        XCTAssertEqual(count("/sdk/chat/conversations"), 1)
    }

    func testTheWaitIsReadFromTheBodyWhenTheHeaderIsMissing() {
        let publicRoute = FeeqdError.from(status: 429, data: Data(#"{"error":"rate_limit_exceeded","retry_after_seconds":30}"#.utf8), retryAfter: nil)
        XCTAssertEqual(publicRoute, .rateLimited(retryAfter: 30))
        let header = FeeqdError.from(status: 429, data: Data(#"{"error":"rate_limited","retry_after":30}"#.utf8), retryAfter: "5")
        XCTAssertEqual(header, .rateLimited(retryAfter: 5), "the header wins")
    }
}

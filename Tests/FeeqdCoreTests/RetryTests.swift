@testable import FeeqdCore
import Foundation
import XCTest

/// A write that fails is sent again, waiting longer each time, when sending it again cannot do
/// anything twice. Reads are not: their screens offer "Try again".
final class RetryTests: XCTestCase {
    override func setUp() {
        StubURLProtocol.reset()
    }

    private let created = Data(#"{"id":"c1","entry_id":"E","content":"Hi"}"#.utf8)

    /// Answers the given responses in order, then the last one for any further request.
    private func answer(_ responses: StubURLProtocol.Response...) {
        StubURLProtocol.responder = { _ in responses[min(StubURLProtocol.requests.count, responses.count) - 1] }
    }

    func testACommentThatNeverLeftTheDeviceIsSentAgainWithGrowingWaits() async throws {
        answer(.failure(.notConnectedToInternet), .failure(.cannotConnectToHost), .init(status: 503), .json(201, created))
        let comment = try await FeeqdClient.stubbed().comment(boardID: "B", entryID: "E", content: "Hi")
        XCTAssertEqual(comment.id, "c1")
        XCTAssertEqual(StubURLProtocol.requests.count, 4)
        XCTAssertEqual(StubURLProtocol.waits, [1, 2, 4])
        XCTAssertEqual(Set(StubURLProtocol.requests.map(\.httpBody)).count, 1, "the same body every time")
    }

    func testAWriteGivesUpAfterFourRetries() async throws {
        answer(.init(status: 503))
        do {
            _ = try await FeeqdClient.stubbed().sendChatMessage(conversationID: "C", body: "Hi")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? FeeqdError, .server(status: 503, code: nil, message: nil))
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 5)
        XCTAssertEqual(StubURLProtocol.waits, [1, 2, 4, 8])
    }

    /// A timeout or a 500 may come after the server stored it: sending it again would post it twice.
    func testANewCommentIsNotSentAgainWhenItMayHaveArrived() async throws {
        for response: StubURLProtocol.Response in [.failure(.timedOut), .failure(.networkConnectionLost), .init(status: 500), .init(status: 504)] {
            StubURLProtocol.reset()
            answer(response)
            _ = try? await FeeqdClient.stubbed().submit(boardID: "B", title: "T", description: "D")
            XCTAssertEqual(StubURLProtocol.requests.count, 1, "\(response)")
        }
    }

    func testAVoteIsSentAgainAfterAnyServerError() async throws {
        answer(.init(status: 500), .failure(.timedOut), .json(200, Data(#"{"entry_id":"E","voted":true,"vote_count":3}"#.utf8)))
        let result = try await FeeqdClient.stubbed().vote(boardID: "B", entryID: "E")
        XCTAssertEqual(result.voteCount, 3)
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertEqual(StubURLProtocol.waits, [1, 2])
    }

    func testARateLimitWaitsWhatTheServerAsks() async throws {
        answer(.init(status: 429, headers: ["Retry-After": "3"]), .json(201, created))
        _ = try await FeeqdClient.stubbed().comment(boardID: "B", entryID: "E", content: "Hi")
        XCTAssertEqual(StubURLProtocol.waits, [3])
    }

    func testAFullPlanIsNotRetried() async throws {
        answer(.json(429, Data(#"{"error":"quota_exceeded"}"#.utf8)))
        _ = try? await FeeqdClient.stubbed().submit(boardID: "B", title: "T", description: "D")
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testReadsAreNotRetried() async throws {
        answer(.init(status: 503))
        _ = try? await FeeqdClient.stubbed().config()
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testTheWaitGrowsToACapWithJitter() {
        let policy = RetryPolicy(maxRetries: 6, baseDelay: 1, maxDelay: 8, jitter: { 0.5 }, sleep: { _ in })
        XCTAssertEqual((0..<6).map(policy.delay), [0.5, 1, 2, 4, 4, 4])
    }
}

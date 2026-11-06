import Foundation

/// How a failed write is sent again: waits that double from `baseDelay` up to `maxDelay`, each
/// shortened by up to half at random so devices that failed together don't come back together.
package struct RetryPolicy: Sendable {
    package var maxRetries: Int
    package var baseDelay: TimeInterval
    package var maxDelay: TimeInterval
    package var jitter: @Sendable () -> Double
    package var sleep: @Sendable (TimeInterval) async throws -> Void

    package init(
        maxRetries: Int,
        baseDelay: TimeInterval,
        maxDelay: TimeInterval,
        jitter: @escaping @Sendable () -> Double,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
        self.sleep = sleep
    }

    /// About 15 seconds at most before the error reaches the screen, which keeps the text.
    package static let standard = RetryPolicy(
        maxRetries: 4,
        baseDelay: 1,
        maxDelay: 8,
        jitter: { .random(in: 0.5...1) },
        sleep: { try await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1_000_000_000)) }
    )

    /// The wait before retry number `retry` (from 0).
    package func delay(_ retry: Int) -> TimeInterval {
        min(maxDelay, baseDelay * pow(2, Double(retry))) * jitter()
    }
}

/// Whether a request may be sent again after it failed.
package enum RepeatSafety: Sendable {
    /// A read: its screen offers "Try again", so only a short rate limit is waited out.
    case read
    /// Sending it twice changes nothing (a vote, marking read): retried after any failure.
    case idempotent
    /// A new comment, request or message. The backend can't tell a repeat from a new one, so it
    /// is sent again only when it surely never reached the server.
    case once
}

extension URLError.Code {
    /// The request failed before any of it reached the server.
    var neverSent: Bool {
        switch self {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}

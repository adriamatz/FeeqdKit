import Foundation

package enum FeeqdError: Error, Equatable, Sendable {
    /// `Feeqd.configure` was never called.
    case notConfigured
    /// The key has no board and the integrator named none.
    case noBoard
    /// Unknown, revoked or expired key.
    case invalidKey
    /// The board does not accept anonymous writes from the SDK.
    case identityRequired
    /// A 404, with the code the body named. `board_not_found` and `entry_not_found` are real
    /// answers about the data; only `not_found`, or a body without a code, says the route itself
    /// is missing on this backend (see `isMissingRoute`).
    case notFound(code: String?)
    /// The key lacks a scope the call needs — for the chat, a key created without `chat`.
    case insufficientScope
    /// The team's plan has no room left this period: for a request, or for a new conversation.
    /// Retrying will not help; the app stops offering it.
    case quotaExceeded
    /// The conversation cannot take the message: it is closed and this backend does not reopen
    /// it, or the device has since opened another one.
    case conversationClosed
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, code: String?, message: String?)
    case transport(String)
    case decoding(String)

    /// The backend has no such route: an older deployment. Not a board the key can't reach, or
    /// an entry that is gone — those must not send a call down a fallback route.
    package var isMissingRoute: Bool {
        if case let .notFound(code) = self { return code == nil || code == "not_found" }
        return false
    }

    package var isRetryable: Bool {
        switch self {
        case .rateLimited, .transport: return true
        case let .server(status, _, _): return status >= 500
        default: return false
        }
    }

    /// A request dropped because its screen went away (the user switched section, or dismissed):
    /// not a failure to show anyone.
    package static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    package static func wrap(_ error: Error) -> FeeqdError {
        if let error = error as? FeeqdError { return error }
        if let error = error as? URLError { return .transport(error.localizedDescription) }
        if error is DecodingError { return .decoding(String(describing: error)) }
        return .transport(String(describing: error))
    }

    /// Maps an HTTP failure. The two services disagree on the body — go-reader answers
    /// `{"detail": "…"}`, go-gatherer `{"error": "code", "message": "…"}` — so both are read.
    package static func from(status: Int, data: Data, retryAfter: String?) -> FeeqdError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        let code = body?.error
        let message = body?.message ?? body?.detail
        switch (status, code) {
        case (401, .some("identity_required")): return .identityRequired
        case (401, _): return .invalidKey
        case (403, .some("insufficient_scope")): return .insufficientScope
        case (404, _): return .notFound(code: code)
        case (409, .some("conversation_closed")), (409, .some("another_conversation_open")): return .conversationClosed
        case (429, .some("quota_exceeded")): return .quotaExceeded
        case (429, _):
            // The header first; go-gatherer also puts it in the body (`retry_after`, or
            // `retry_after_seconds` on the public routes).
            let seconds = retryAfter.flatMap { TimeInterval($0.feeqdTrimmed) } ?? body?.retryAfter
            return .rateLimited(retryAfter: seconds)
        default: return .server(status: status, code: code, message: message)
        }
    }
}

private struct ErrorBody: Decodable {
    let error: String?
    let message: String?
    let detail: String?
    let retryAfter: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case error, message, detail
        case retryAfter = "retry_after", retryAfterSeconds = "retry_after_seconds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        error = try? c.decode(String.self, forKey: .error)
        message = try? c.decode(String.self, forKey: .message)
        detail = try? c.decode(String.self, forKey: .detail)
        retryAfter = (try? c.decode(TimeInterval.self, forKey: .retryAfter)) ?? (try? c.decode(TimeInterval.self, forKey: .retryAfterSeconds))
    }
}

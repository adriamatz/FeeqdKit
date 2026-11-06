import FeeqdCore
import Foundation
import XCTest

/// Responses captured from the local stack (`feeqd-back@f193f22`) on 2026-09-11. Tests decode
/// what the server really sends, not what we believe it sends.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw XCTSkip("Missing fixture \(name).json")
        }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder.feeqd.decode(T.self, from: data(name))
    }
}

/// Answers `URLSession` requests from a closure and records what was sent.
final class StubURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        /// Set to fail the request before any answer, the way a dropped connection does.
        var error: URLError.Code?

        static func failure(_ code: URLError.Code) -> Response { Response(status: 0, error: code) }

        static func json(_ status: Int, _ body: Data, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: body)
        }
    }

    // Set by a test before it runs and read by the protocol while it does: the tests run one
    // at a time, so the unchecked access is never concurrent.
    nonisolated(unsafe) static var responder: ((URLRequest) -> Response)?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    /// Every wait the client asked for between attempts, in order. Nobody really waits.
    nonisolated(unsafe) static var waits: [TimeInterval] = []

    static func reset() {
        responder = nil
        requests = []
        waits = []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            recorded.httpBody = Data(reading: stream)
        }
        Self.requests.append(recorded)
        let response = Self.responder?(recorded) ?? Response(status: 500)
        if let code = response.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Data {
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            append(buffer, count: read)
        }
    }
}

extension FeeqdClient {
    static func stubbed(deviceID: String = "dev_test_device") -> FeeqdClient {
        stubbed(identity: DeviceIdentity(store: InMemorySecretStore([DeviceIdentity.account: deviceID])))
    }

    static func stubbed(identity: DeviceIdentity) -> FeeqdClient {
        FeeqdClient(
            configuration: ClientConfiguration(
                apiKey: "feeqd_pk_test",
                readerURL: URL(string: "http://reader.test")!,
                gathererURL: URL(string: "http://gatherer.test")!
            ),
            session: StubURLProtocol.session(),
            identity: identity,
            retryPolicy: RetryPolicy(maxRetries: 4, baseDelay: 1, maxDelay: 8, jitter: { 1 }, sleep: { StubURLProtocol.waits.append($0) }),
            outbox: Outbox(fileURL: nil)
        )
    }
}

import Foundation
@testable import AICreditsApp

/// Each session has an independent fixture. No tests read Keychain or make live API calls.
final class HTTPFixture: @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body: String
        var delay: TimeInterval = 0
        var error: URLError?
    }
    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [URLRequest] = []
    var onRequest: (@Sendable (URLRequest) -> Void)?

    init(_ replies: [Reply]) { self.replies = replies }
    var requests: [URLRequest] { lock.withLock { recorded } }
    func next(_ request: URLRequest) -> Reply {
        let reply = lock.withLock {
            recorded.append(request)
            return replies.isEmpty ? Reply(status: 599, body: "Unexpected request") : replies.removeFirst()
        }
        onRequest?(request)
        return reply
    }
    func makeClient() -> BillingHTTPClient {
        let id = UUID().uuidString
        StubURLProtocol.register(self, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Fixture": id]
        return BillingHTTPClient(session: URLSession(configuration: configuration), sleep: { _ in })
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: HTTPFixture] = [:]

    static func register(_ fixture: HTTPFixture, id: String) {
        lock.withLock { fixtures[id] = fixture }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.lock.withLock { Self.fixtures[request.value(forHTTPHeaderField: "X-Test-Fixture") ?? ""] }
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let reply = fixture.next(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            if let error = reply.error {
                client?.urlProtocol(self, didFailWithError: error)
            } else {
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() {}
}

final class MemoryCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CreditPlatform: String]
    private let readError: OSStatus?
    init(_ values: [CreditPlatform: String] = [:], readError: OSStatus? = nil) {
        self.values = values
        self.readError = readError
    }
    func get(for platform: CreditPlatform, allowInteraction: Bool) throws -> String? {
        if let readError { throw KeychainError.status(readError) }
        return lock.withLock { values[platform] }
    }
    func set(_ value: String, for platform: CreditPlatform) throws { lock.withLock { values[platform] = value } }
    func delete(for platform: CreditPlatform) throws { _ = lock.withLock { values.removeValue(forKey: platform) } }
}

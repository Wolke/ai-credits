import XCTest
import Combine
import Security
@testable import AICreditsApp

@MainActor
final class SyncDiagnosticsTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    private func persistence() -> PersistenceService {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        directories.append(directory)
        return PersistenceService(fileURL: directory.appending(path: "credits.json"))
    }

    private func store(_ fixture: HTTPFixture, credentials: MemoryCredentials = MemoryCredentials([.elevenLabs: "test-key"]), persistence: PersistenceService? = nil) -> AppStore {
        AppStore(persistence: persistence ?? self.persistence(), keychain: credentials, client: fixture.makeClient(), automaticallyRefresh: false)
    }

    func testMissingKeyHasAttemptTimeButNoHTTPRequest() async {
        let fixture = HTTPFixture([])
        let store = store(fixture, credentials: MemoryCredentials())
        await store.refresh(platform: .elevenLabs)
        let status = store.status(for: .elevenLabs)
        XCTAssertEqual(status.state, .notConfigured)
        XCTAssertNotNil(status.attemptedAt)
        XCTAssertEqual(status.requestCount, 0)
        XCTAssertNil(status.lastHTTPStatus)
        XCTAssertTrue(status.message.contains("未發起 API 請求"))
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertTrue(store.data.syncEvents?.last?.message.contains("略過") == true)
    }

    func testKeychainFailureIsVisibleWithoutClaimingAPICall() async {
        let fixture = HTTPFixture([])
        let store = store(fixture, credentials: MemoryCredentials(readError: errSecInteractionNotAllowed))
        await store.refresh(platform: .elevenLabs)
        XCTAssertEqual(store.status(for: .elevenLabs).state, .failed)
        XCTAssertEqual(store.status(for: .elevenLabs).requestCount, 0)
        XCTAssertTrue(store.data.syncEvents?.last?.message.contains("Keychain") == true)
    }

    func testHTTPFailureKeepsCodeAttemptAndSuccessTimeAcrossRestart() async throws {
        let fixture = HTTPFixture([
            .init(body: #"{"tier":"free","character_count":1,"character_limit":100}"#),
            .init(status: 403, body: #"{"detail":{"message":"Forbidden"}}"#)
        ])
        let persistence = persistence()
        let store = store(fixture, persistence: persistence)
        await store.refresh(platform: .elevenLabs)
        let success = store.status(for: .elevenLabs).lastSuccessAt
        await store.refresh(platform: .elevenLabs)
        let status = store.status(for: .elevenLabs)
        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.requestCount, 1)
        XCTAssertEqual(status.lastHTTPStatus, 403)
        XCTAssertEqual(status.lastSuccessAt, success)
        XCTAssertEqual(store.data.entries.first?.remainingAmount, 99)
        let relaunched = AppStore(persistence: persistence, keychain: MemoryCredentials(), automaticallyRefresh: false)
        XCTAssertEqual(relaunched.status(for: .elevenLabs).state, .failed)
        XCTAssertEqual(relaunched.status(for: .elevenLabs).lastHTTPStatus, 403)
        XCTAssertNotNil(relaunched.status(for: .elevenLabs).lastSuccessAt)
        XCTAssertTrue(relaunched.data.lastRefreshError?.contains("403") == true)
        XCTAssertTrue(relaunched.data.syncEvents?.contains { $0.message.contains("收到 HTTP 403") } == true)
    }

    func testRetryIsVisibleWhileRequestIsStillRunning() async throws {
        let retryStarted = expectation(description: "Retry state published before completion")
        let fixture = HTTPFixture([
            .init(status: 503, body: "{}"),
            .init(body: #"{"tier":"free","character_count":2,"character_limit":100}"#)
        ])
        var client = fixture.makeClient()
        client.sleep = { _ in try await Task.sleep(for: .milliseconds(50)) }
        let store = AppStore(persistence: persistence(), keychain: MemoryCredentials([.elevenLabs: "test-key"]), client: client, automaticallyRefresh: false)
        let observation = store.$providerStatuses.first { $0[.elevenLabs]?.message.contains("秒後重試") == true }
            .sink { states in
                XCTAssertEqual(states[.elevenLabs]?.state, .syncing)
                XCTAssertEqual(states[.elevenLabs]?.requestCount, 1)
                retryStarted.fulfill()
            }
        await store.refresh(platform: .elevenLabs)
        await fulfillment(of: [retryStarted], timeout: 2)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(store.status(for: .elevenLabs).requestCount, 2)
        XCTAssertEqual(store.status(for: .elevenLabs).lastHTTPStatus, 200)
        XCTAssertEqual(store.status(for: .elevenLabs).state, .success)
        XCTAssertTrue(store.data.syncEvents?.contains { $0.message.contains("503") } == true)
    }

    func testDecodingFailureIsNotReportedAsSuccessfulHTTP200Sync() async {
        let fixture = HTTPFixture([.init(body: #"{"unexpected":"value"}"#)])
        let store = store(fixture)
        await store.refresh(platform: .elevenLabs)
        XCTAssertEqual(store.status(for: .elevenLabs).lastHTTPStatus, 200)
        XCTAssertEqual(store.status(for: .elevenLabs).state, .failed)
        XCTAssertNil(store.status(for: .elevenLabs).lastSuccessAt)
        XCTAssertTrue(store.status(for: .elevenLabs).message.contains("資料格式不符"))
    }

    func testMissingUserReadPermissionHasActionableMessage() async {
        let fixture = HTTPFixture([.init(status: 401, body: #"{"detail":{"status":"missing_permissions","message":"The API key you used is missing the permission user_read to execute this operation."}}"#)])
        let store = store(fixture)
        await store.refresh(platform: .elevenLabs)
        let status = store.status(for: .elevenLabs)
        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.lastHTTPStatus, 401)
        XCTAssertEqual(status.requestCount, 1)
        XCTAssertTrue(status.message.contains("User → Read（user_read）"))
        XCTAssertTrue(status.message.contains("Developers → API Keys"))
    }

    func testInterruptedSyncBecomesFailureAfterRestart() throws {
        let persistence = persistence()
        let data = AppData(providerSyncStatuses: [.elevenLabs: .syncing])
        try persistence.save(data)
        let store = AppStore(persistence: persistence, keychain: MemoryCredentials(), automaticallyRefresh: false)
        XCTAssertEqual(store.status(for: .elevenLabs).state, .failed)
        XCTAssertTrue(store.status(for: .elevenLabs).message.contains("上次同步未完成"))
        XCTAssertTrue(store.data.lastRefreshError?.contains("上次同步未完成") == true)
    }

    func testDiagnosticsNeverPersistCredentialEchoOrUnboundedHistory() async throws {
        let key = "private-fixture-value-" + String(repeating: "x", count: 700)
        let fixture = HTTPFixture([.init(status: 401, body: "{\"detail\":{\"message\":\"Invalid key: \(key)\"}}")])
        let persistence = persistence()
        let events = (0..<150).map { SyncEvent(platform: .openAI, date: .now, message: "Previous event \($0)") }
        try persistence.save(AppData(syncEvents: events))
        let store = store(fixture, credentials: MemoryCredentials([.elevenLabs: key]), persistence: persistence)
        await store.refresh(platform: .elevenLabs)
        let saved = try String(contentsOf: persistence.fileURL, encoding: .utf8)
        XCTAssertFalse(saved.contains("private-fixture-value"))
        XCTAssertFalse(saved.contains(String(repeating: "x", count: 100)))
        XCTAssertEqual(store.data.syncEvents?.count, 120)
        XCTAssertTrue(saved.contains("已隱藏金鑰"))
    }

    func testRequestLogExcludesQueryAndAuthorization() async throws {
        let fixture = HTTPFixture([.init(body: "OK")])
        let events = EventCollector()
        var client = fixture.makeClient()
        client.onEvent = { await events.append($0) }
        var request = URLRequest(url: URL(string: "https://example.invalid/usage?token=private-query")!)
        request.setValue("Bearer private-header", forHTTPHeaderField: "Authorization")
        _ = try await client.data(for: request)
        let output = await events.output()
        XCTAssertTrue(output.contains("GET example.invalid/usage"))
        XCTAssertFalse(output.contains("private-query"))
        XCTAssertFalse(output.contains("private-header"))
    }
}

private actor EventCollector {
    private var events: [BillingRequestEvent] = []
    func append(_ event: BillingRequestEvent) { events.append(event) }
    func output() -> String { events.map { $0.endpoint + " " + $0.message }.joined(separator: "\n") }
}

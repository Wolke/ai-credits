import XCTest
import Security
import Combine
@testable import AICreditsApp

@MainActor
final class AppStoreSyncTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    private func store(fixture: HTTPFixture, credentials: MemoryCredentials, data: AppData = AppData(), automaticallyRefresh: Bool = false) throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        directories.append(directory)
        let persistence = PersistenceService(fileURL: directory.appending(path: "credits.json"))
        try persistence.save(data)
        return AppStore(persistence: persistence, keychain: credentials, client: fixture.makeClient(), automaticallyRefresh: automaticallyRefresh)
    }

    func testRepeatedRefreshContinuesUpdatingExistingGrant() async throws {
        let fixture = HTTPFixture([
            .init(body: #"{"data":[{"results":[{"amount":{"value":20,"currency":"usd"}}]}],"has_more":false}"#),
            .init(body: #"{"data":[{"results":[{"amount":{"value":25,"currency":"usd"}}]}],"has_more":false}"#),
            .init(body: #"{"data":[{"results":[{"amount":{"value":27,"currency":"usd"}}]}],"has_more":false}"#)
        ])
        let grant = CreditEntry(originalAmount: 100, remainingAmount: 80, receivedAt: .now.addingTimeInterval(-86_400))
        let store = try store(fixture: fixture, credentials: MemoryCredentials([.openAI: "test"]), data: AppData(entries: [grant]))
        await store.refresh(platform: .openAI)
        await store.refresh(platform: .openAI)
        await store.refresh(platform: .openAI)
        XCTAssertEqual(store.data.entries[0].remainingAmount, 73)
        XCTAssertNotNil(store.data.entries[0].lastSyncedAt)
        XCTAssertEqual(store.providerStatuses[.openAI]?.state, .success)
        XCTAssertFalse(store.isRefreshing)
    }

    func testSavedKeyIsReadOnEverySyncAndElevenLabsNeedsNoManualEntry() async throws {
        let fixture = HTTPFixture([
            .init(body: #"{"tier":"creator","character_count":100,"character_limit":1000}"#),
            .init(body: #"{"tier":"creator","character_count":250,"character_limit":1000}"#)
        ])
        let credentials = MemoryCredentials([.elevenLabs: "saved-key"])
        let store = try store(fixture: fixture, credentials: credentials)
        await store.refresh(platform: .elevenLabs)
        await store.refresh(platform: .elevenLabs)
        XCTAssertEqual(store.data.entries.count, 1)
        XCTAssertEqual(store.data.entries[0].remainingAmount, 750)
        XCTAssertEqual(fixture.requests.map { $0.value(forHTTPHeaderField: "xi-api-key") }, ["saved-key", "saved-key"])
        XCTAssertNil(store.nearestEntry, "A missing reset date must not produce a made-up menu countdown")
    }

    func testLaunchTriggersSyncAndMenuRefreshUsesCooldown() async throws {
        let completed = expectation(description: "Startup sync completed")
        let fixture = HTTPFixture([.init(body: #"{"tier":"free","character_count":10,"character_limit":100}"#)])
        let store = try store(fixture: fixture, credentials: MemoryCredentials([.elevenLabs: "test"]), automaticallyRefresh: true)
        let observation = store.$data.first { $0.entries.count == 1 && $0.lastRefreshAt != nil }
            .sink { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 2)
        await store.refreshIfNeeded()
        withExtendedLifetime(observation) {}
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(store.data.entries.first?.remainingAmount, 90)
    }

    func testSimultaneousRefreshesWaitForSameRequest() async throws {
        let fixture = HTTPFixture([.init(body: #"{"tier":"free","character_count":100,"character_limit":1000}"#, delay: 0.1)])
        let store = try store(fixture: fixture, credentials: MemoryCredentials([.elevenLabs: "test"]))
        async let first: Void = store.refresh(platform: .elevenLabs)
        async let second: Void = store.refresh(platform: .elevenLabs)
        _ = await (first, second)
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(store.data.entries.count, 1)
        XCTAssertFalse(store.isRefreshing)
    }

    func testKeyReplacementIgnoresOldResponseAndTestsNewKey() async throws {
        let requested = expectation(description: "Old key request")
        let fixture = HTTPFixture([
            .init(body: #"{"tier":"old","character_count":0,"character_limit":9999}"#, delay: 0.15),
            .init(body: #"{"tier":"new","character_count":200,"character_limit":1000}"#)
        ])
        fixture.onRequest = { request in
            if request.value(forHTTPHeaderField: "xi-api-key") == "old-key" { requested.fulfill() }
        }
        let store = try store(fixture: fixture, credentials: MemoryCredentials([.elevenLabs: "old-key"]))
        let first = Task { await store.refresh(platform: .elevenLabs) }
        await fulfillment(of: [requested], timeout: 2)
        try store.setAPIKey("new-key", for: .elevenLabs)
        await store.refresh(platform: .elevenLabs)
        await first.value
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(store.data.entries.count, 1)
        XCTAssertEqual(store.data.entries[0].remainingAmount, 800)
        XCTAssertEqual(store.data.entries[0].name, "New 方案")
        XCTAssertFalse(store.isRefreshing)
    }

    func testKeychainFailureIsReportedInsteadOfClaimingKeyIsMissing() async throws {
        let fixture = HTTPFixture([])
        let store = try store(fixture: fixture, credentials: MemoryCredentials(readError: errSecInteractionNotAllowed))
        await store.refresh(platform: .openAI)
        XCTAssertEqual(store.providerStatuses[.openAI]?.state, .failed)
        XCTAssertTrue(store.data.lastRefreshError?.contains("Keychain") == true)
        XCTAssertNil(store.data.lastRefreshAt)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testFailurePreservesBalanceAndLastSuccessAndSurvivesOtherPlatformRefresh() async throws {
        let fixture = HTTPFixture([.init(status: 401, body: #"{"detail":{"message":"invalid test-key"}}"#)])
        let lastSuccess = Date(timeIntervalSince1970: 1_800_000_000)
        let data = AppData(entries: [CreditEntry(originalAmount: 100, remainingAmount: 80)], lastRefreshAt: lastSuccess)
        let store = try store(fixture: fixture, credentials: MemoryCredentials([.elevenLabs: "test-key"]), data: data)
        await store.refresh(platform: .elevenLabs)
        await store.refresh(platform: .openAI)
        XCTAssertEqual(store.data.entries[0].remainingAmount, 80)
        XCTAssertEqual(store.data.lastRefreshAt, lastSuccess)
        XCTAssertTrue(store.data.lastRefreshError?.contains("ElevenLabs") == true)
        XCTAssertFalse(store.data.lastRefreshError?.contains("test-key") == true)
    }

    func testExhaustedSubscriptionRemainsVisibleUntilRenewal() async throws {
        let fixture = HTTPFixture([.init(body: #"{"tier":"free","character_count":1000,"character_limit":1000}"#)])
        let store = try store(fixture: fixture, credentials: MemoryCredentials([.elevenLabs: "test"]))
        await store.refresh(platform: .elevenLabs)
        XCTAssertEqual(store.currentEntries.count, 1)
        XCTAssertEqual(store.currentEntries[0].remainingAmount, 0)
    }
}

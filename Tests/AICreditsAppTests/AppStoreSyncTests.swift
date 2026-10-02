import XCTest
import Security
import Combine
@testable import AICreditsApp

@MainActor
final class AppStoreSyncTests: XCTestCase {
    private var directories: [URL] = []

    private func store(fixture: HTTPFixture, credentials: MemoryCredentials, data: AppData = AppData(), automaticallyRefresh: Bool = false) throws -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        directories.append(directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
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

    func testCorrectionIsLoggedAndEnablesAutomaticOriginalBalance() async throws {
        let start = Date.now.addingTimeInterval(-86_400)
        let fixture = HTTPFixture([
            .init(body: #"{"data":[{"results":[{"amount":"442581.02765"}]}],"has_more":false}"#),
            .init(body: #"{"data":[{"results":[{"amount":"443581.02765"}]}],"has_more":false}"#)
        ])
        let entry = CreditEntry(platform: .claude, originalAmount: 5000, remainingAmount: 4968,
            receivedAt: start, expiresAt: start.addingTimeInterval(86_400 * 90))
        let store = try store(fixture: fixture, credentials: MemoryCredentials([.claude: "test"]), data: AppData(entries: [entry]))
        await store.refresh(platform: .claude)
        XCTAssertTrue(store.status(for: .claude).message.contains("尚未扣除歷史花費"))
        let proposal = try XCTUnwrap(store.reconciliation(for: .claude))
        try store.reconcile(proposal)
        XCTAssertEqual(store.data.entries[0].remainingAmount, Decimal(string: "574.1897235"))
        XCTAssertFalse(store.status(for: .claude).message.contains("尚未扣除歷史花費"))
        XCTAssertTrue(store.data.syncEvents?.last?.message.contains("已按原始總額校正") == true)
        await store.refresh(platform: .claude)
        XCTAssertEqual(store.data.entries[0].remainingAmount, Decimal(string: "564.1897235"))
        XCTAssertTrue(store.status(for: .claude).message.contains("每次同步自動重算"))
        XCTAssertTrue(store.data.entries[0].usesOriginalCostBalance)
    }

    func testOriginalBalanceLoadsCorrectlyWithoutAWorkingAPIAndRecalculatesEdits() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = CreditEntry(platform: .claude, originalAmount: 5000, remainingAmount: 4968,
            receivedAt: start, expiresAt: start.addingTimeInterval(86_400 * 90), calculatesFromOriginal: true)
        let data = AppData(entries: [entry], providerLastCosts: [.claude: 4428],
            costSyncStates: [.claude: CostSyncState(since: start, cumulativeCost: 4500, currency: "USD", fetchedAt: start.addingTimeInterval(60))],
            providerSyncStatuses: [.claude: .failed("上次連線失敗")])
        let fixture = HTTPFixture([])
        let store = try store(fixture: fixture, credentials: MemoryCredentials(), data: data)
        XCTAssertEqual(store.data.entries[0].remainingAmount, 572)
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertEqual(store.status(for: .claude).state, .failed, "Cached calculation must not hide connection errors")
        let disk = try PersistenceService(fileURL: directories.last!.appending(path: "credits.json")).load()
        XCTAssertEqual(disk.entries[0].remainingAmount, 572)
        var edited = store.data.entries[0]
        edited.originalAmount = 6000
        store.upsert(edited)
        XCTAssertEqual(store.data.entries[0].remainingAmount, 1572)
    }

    func testFirstAPIResponseCalculatesFromOriginalAndFailuresPreserveIt() async throws {
        let fixture = HTTPFixture([
            .init(body: #"{"data":[{"results":[{"amount":"442800"}]}],"has_more":false}"#),
            .init(status: 401, body: #"{"error":{"message":"not authorized"}}"#)
        ])
        let entry = CreditEntry(platform: .claude, originalAmount: 5000, remainingAmount: 4968,
            receivedAt: .now.addingTimeInterval(-86_400), calculatesFromOriginal: true)
        let store = try store(fixture: fixture, credentials: MemoryCredentials([.claude: "test"]), data: AppData(entries: [entry]))
        await store.refresh(platform: .claude)
        XCTAssertEqual(store.data.entries[0].remainingAmount, 572)
        XCTAssertTrue(store.status(for: .claude).message.contains("每次同步自動重算"))
        let success = store.status(for: .claude).lastSuccessAt
        await store.refresh(platform: .claude)
        XCTAssertEqual(store.data.entries[0].remainingAmount, 572)
        XCTAssertEqual(store.status(for: .claude).state, .failed)
        XCTAssertEqual(store.status(for: .claude).lastSuccessAt, success)
    }

    func testReplacingKeyRejectsOldBalanceCorrection() async throws {
        let fixture = HTTPFixture([.init(body: #"{"data":[{"results":[{"amount":"2000"}]}],"has_more":false}"#)])
        let entry = CreditEntry(platform: .claude, originalAmount: 100, remainingAmount: 100, receivedAt: .now.addingTimeInterval(-86_400))
        let store = try store(fixture: fixture, credentials: MemoryCredentials([.claude: "test"]), data: AppData(entries: [entry]))
        await store.refresh(platform: .claude)
        let proposal = try XCTUnwrap(store.reconciliation(for: .claude))
        try store.setAPIKey("different-account", for: .claude)
        XCTAssertThrowsError(try store.reconcile(proposal))
        XCTAssertEqual(store.data.entries[0].remainingAmount, 100)
    }

    func testOpenAICurrentPoolSubtractsPeriodSpendOnceAndLeavesExpiredGrantsUntouched() async throws {
        let fixture = HTTPFixture(["4131.312155995"].map { cost in
            .init(body: "{\"data\":[{\"results\":[{\"amount\":{\"value\":\(cost),\"currency\":\"usd\"}}]}],\"has_more\":false}")
        })
        let live = CreditEntry(platform: .openAI, originalAmount: 5000, remainingAmount: Decimal(string: "2199.92")!,
            receivedAt: .now.addingTimeInterval(-4 * 86_400), expiresAt: .now.addingTimeInterval(90 * 86_400), calculatesFromOriginal: true)
        let old = CreditEntry(platform: .openAI, originalAmount: 1200, remainingAmount: 1200,
            receivedAt: .now.addingTimeInterval(-3 * 86_400), expiresAt: .now.addingTimeInterval(-2 * 86_400), calculatesFromOriginal: true)
        let later = CreditEntry(platform: .openAI, originalAmount: 5000, remainingAmount: 5000,
            receivedAt: .now.addingTimeInterval(-2 * 86_400), expiresAt: .now.addingTimeInterval(180 * 86_400), calculatesFromOriginal: true)
        let small = CreditEntry(platform: .openAI, originalAmount: 250, remainingAmount: 250,
            receivedAt: .now.addingTimeInterval(-86_400), expiresAt: .now.addingTimeInterval(210 * 86_400), calculatesFromOriginal: true)
        let store = try store(fixture: fixture, credentials: MemoryCredentials([.openAI: "test"]), data: AppData(entries: [live, old, later, small]))
        let savedOld = store.data.entries[1]
        await store.refresh(platform: .openAI)
        XCTAssertEqual(store.data.entries[0].remainingAmount, Decimal(string: "868.687844005"))
        XCTAssertEqual(store.data.entries[1], savedOld)
        XCTAssertEqual(store.activeReconciliation(for: .openAI)?.remaining, Decimal(string: "6118.687844005"))
        XCTAssertEqual(store.status(for: .openAI).state, .success)
        XCTAssertTrue(store.status(for: .openAI).message.contains("已到期額度不參與抵扣"))
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testCachedOpenAIPoolRecalculatesOnStartupAndEditWithoutFakingAPISuccess() throws {
        let now = Date.now
        let start = Date(timeIntervalSince1970: floor(now.addingTimeInterval(-4 * 86_400).timeIntervalSince1970))
        let live = CreditEntry(platform: .openAI, originalAmount: 5000, remainingAmount: 5000,
            receivedAt: start, expiresAt: now.addingTimeInterval(90 * 86_400), calculatesFromOriginal: true)
        let later = CreditEntry(platform: .openAI, originalAmount: 5000, remainingAmount: 5000,
            receivedAt: start.addingTimeInterval(86_400), expiresAt: now.addingTimeInterval(180 * 86_400), calculatesFromOriginal: true)
        let cost = Decimal(string: "4131.312155995")!
        let failed = ProviderSyncStatus.failed("Keychain authorization required")
        let data = AppData(entries: [live, later], providerLastCosts: [.openAI: cost], costSyncStates: [
            .openAI: CostSyncState(since: start, cumulativeCost: cost, currency: "USD", fetchedAt: now)
        ], providerSyncStatuses: [.openAI: failed])
        let fixture = HTTPFixture([])
        let store = try store(fixture: fixture, credentials: MemoryCredentials(), data: data)
        XCTAssertEqual(store.data.entries[0].remainingAmount, Decimal(string: "868.687844005"))
        XCTAssertEqual(store.status(for: .openAI), failed)
        var edited = store.data.entries[0]
        edited.originalAmount = 6000
        store.upsert(edited)
        XCTAssertEqual(store.data.entries[0].remainingAmount, Decimal(string: "1868.687844005"))
        XCTAssertEqual(store.status(for: .openAI), failed)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testSavingDollarValuationChangesOnlyElevenLabsDisplayAndNewAccountClearsIt() throws {
        let entry = CreditEntry(platform: .elevenLabs, originalAmount: 1000, remainingAmount: 700, unit: "credits", isSubscriptionBalance: true)
        let fixture = HTTPFixture([])
        let failed = ProviderSyncStatus.failed("connection unavailable")
        let store = try store(fixture: fixture, credentials: MemoryCredentials([.elevenLabs: "old-key"]),
            data: AppData(entries: [entry], providerSyncStatuses: [.elevenLabs: failed]))
        let original = store.data.entries
        XCTAssertNil(store.estimatedUSD(for: entry))
        try store.setElevenLabsUSDValuation(.init(credits: 1000, usd: 10))
        XCTAssertEqual(store.estimatedUSD(for: entry), 7)
        XCTAssertEqual(store.estimatedUSD(for: try XCTUnwrap(store.balanceSummaries.first)), 7)
        XCTAssertEqual(store.data.entries, original)
        XCTAssertEqual(store.status(for: .elevenLabs), failed)
        XCTAssertNil(store.estimatedUSD(for: CreditEntry(platform: .openAI, remainingAmount: 700)))
        XCTAssertNil(store.estimatedUSD(for: CreditEntry(platform: .elevenLabs, remainingAmount: 700, unit: "USD")))
        XCTAssertThrowsError(try store.setElevenLabsUSDValuation(.init(credits: 0, usd: 10)))
        XCTAssertEqual(store.estimatedUSD(for: entry), 7)
        try store.setAPIKey("new-key", for: .elevenLabs)
        XCTAssertNil(store.data.elevenLabsUSDValuation, "A different account must not inherit the previous grant valuation")
        XCTAssertTrue(fixture.requests.isEmpty)
    }
}

import XCTest
@testable import AICreditsApp

final class CostSynchronizerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func usage(_ cost: Decimal) -> ProviderUsage {
        ProviderUsage(platform: .openAI, cumulativeCost: cost, currency: "USD", fetchedAt: start.addingTimeInterval(86_400))
    }
    private func grant(_ amount: Decimal = 80) -> CreditEntry {
        CreditEntry(platform: .openAI, originalAmount: 100, remainingAmount: amount, receivedAt: start, expiresAt: start.addingTimeInterval(180 * 86_400))
    }

    func testMigrationPreservesBalanceThenDeductsOnlyNewUsageOnce() {
        var data = AppData(entries: [grant()], providerLastCosts: [.openAI: 5])
        CostSynchronizer.apply(usage(500), since: start, source: nil, to: &data)
        XCTAssertEqual(data.entries[0].remainingAmount, 80)
        CostSynchronizer.apply(usage(507), since: start, source: nil, to: &data)
        XCTAssertEqual(data.entries[0].remainingAmount, 73)
        CostSynchronizer.apply(usage(507), since: start, source: nil, to: &data)
        XCTAssertEqual(data.entries[0].remainingAmount, 73)
    }

    func testExhaustingOrDeletingFirstGrantDoesNotMoveQueryStart() {
        var second = grant(20)
        second.receivedAt = start.addingTimeInterval(500)
        second.expiresAt = start.addingTimeInterval(181 * 86_400)
        var data = AppData(entries: [grant(1), second])
        CostSynchronizer.apply(usage(100), since: start, source: nil, to: &data)
        CostSynchronizer.apply(usage(105), since: start, source: nil, to: &data)
        XCTAssertEqual(data.entries.map(\.remainingAmount), [0, 16])
        data.entries.removeFirst()
        XCTAssertEqual(CostSynchronizer.startDate(for: .openAI, in: data, now: start.addingTimeInterval(900), source: nil), start)
        CostSynchronizer.apply(usage(108), since: start, source: nil, to: &data)
        XCTAssertEqual(data.entries[0].remainingAmount, 13)
    }

    func testChangedSourceRebaselinesWithoutChargingUnrelatedHistory() {
        var data = AppData(entries: [grant()])
        CostSynchronizer.apply(usage(10), since: start, source: "first", to: &data)
        CostSynchronizer.apply(usage(900), since: start, source: "second", to: &data)
        XCTAssertEqual(data.entries[0].remainingAmount, 80)
    }

    func testTemporaryCostDecreaseDoesNotChargeSameUsageAgain() {
        var data = AppData(entries: [grant()])
        for cost in [100, 110, 105, 110, 112] {
            CostSynchronizer.apply(usage(Decimal(cost)), since: start, source: nil, to: &data)
        }
        XCTAssertEqual(data.entries[0].remainingAmount, 68)
    }

    func testElevenLabsRepeatedSyncAndRenewalKeepOneEntryAndManualCredits() {
        let manual = CreditEntry(platform: .elevenLabs, name: "Manual", originalAmount: 5, remainingAmount: 5)
        var data = AppData(entries: [manual])
        let reset = start.addingTimeInterval(86_400 * 30)
        CostSynchronizer.apply(ElevenLabsBalance(limit: 100, used: 100, resetsAt: reset, tier: "starter", fetchedAt: start), to: &data)
        let id = data.entries[1].id
        CostSynchronizer.apply(ElevenLabsBalance(limit: 100, used: 0, resetsAt: reset.addingTimeInterval(86_400 * 30), tier: "starter", fetchedAt: reset), to: &data)
        XCTAssertEqual(data.entries.count, 2)
        XCTAssertEqual(data.entries[1].id, id)
        XCTAssertEqual(data.entries[1].remainingAmount, 100)
        XCTAssertEqual(data.entries[1].expiresAt, reset.addingTimeInterval(86_400 * 30))
        XCTAssertEqual(data.entries[0], manual)
    }

    func testElevenLabsUnknownResetDoesNotBecomeAnExpiration() {
        var data = AppData()
        CostSynchronizer.apply(ElevenLabsBalance(limit: 100, used: 20, resetsAt: nil, tier: "free", fetchedAt: .now), to: &data)
        XCTAssertFalse(data.entries[0].hasKnownExpiration)
        XCTAssertEqual(data.entries[0].urgency(), .normal)
    }

    func testOldSavedDataLoadsAndNewBaselineSurvivesRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceService(fileURL: directory.appending(path: "credits.json"))
        var data = AppData(entries: [grant()], providerLastCosts: [.openAI: 5])
        try persistence.save(data)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: persistence.fileURL)) as? [String: Any])
        object.removeValue(forKey: "costSyncStates")
        try JSONSerialization.data(withJSONObject: object).write(to: persistence.fileURL)
        data = try persistence.load()
        XCTAssertEqual(data.entries.count, 1)
        CostSynchronizer.apply(usage(500), since: start, source: nil, to: &data)
        try persistence.save(data)
        data = try persistence.load()
        CostSynchronizer.apply(usage(507), since: start, source: nil, to: &data)
        XCTAssertEqual(data.entries[0].remainingAmount, 73)
    }
}

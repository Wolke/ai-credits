import XCTest
@testable import AICreditsApp

final class HistoricalBalanceReconciliationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(_ day: Int) -> Date { Date(timeIntervalSince1970: Double(day) * 86_400) }

    private func fixture() -> AppData {
        let long = CreditEntry(platform: .openAI, originalAmount: 5000, remainingAmount: Decimal(string: "2199.92")!,
            receivedAt: date(0), expiresAt: date(9), calculatesFromOriginal: true)
        let expiring = CreditEntry(platform: .openAI, originalAmount: 1200, remainingAmount: 1200,
            receivedAt: date(2), expiresAt: date(3), calculatesFromOriginal: true)
        let later = CreditEntry(platform: .openAI, originalAmount: 5000, remainingAmount: 5000,
            receivedAt: date(5), expiresAt: date(20), calculatesFromOriginal: true)
        let periods = [
            CostBucket(start: date(0), end: date(2), cost: 1000),
            CostBucket(start: date(2), end: date(4), cost: 400),
            CostBucket(start: date(4), end: date(5), cost: 200),
            CostBucket(start: date(5), end: date(6), cost: Decimal(string: "2531.312155995")!)
        ]
        return AppData(entries: [long, expiring, later], providerLastCosts: [.openAI: Decimal(string: "4131.312155995")!],
            costSyncStates: [.openAI: CostSyncState(since: date(0), cumulativeCost: Decimal(string: "4131.312155995")!,
                currency: "USD", fetchedAt: date(6), allocationCosts: periods)])
    }

    func testReplayCountsExpiredGrantPaymentsButExcludesItsUnusedRemainder() throws {
        var data = fixture()
        let result = try HistoricalBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar)
        XCTAssertEqual(result.rows[0].remaining, Decimal(string: "1268.687844005"))
        XCTAssertEqual(result.rows[1].spent, 400)
        XCTAssertEqual(result.rows[1].remaining, 800)
        XCTAssertEqual(result.rows[2].remaining, 5000)
        XCTAssertEqual(result.expiredUnused, 800)
        XCTAssertEqual(result.remaining, Decimal(string: "6268.687844005"))
        XCTAssertEqual(result.uncoveredCost, 0)
        result.apply(to: &data)
        let again = try HistoricalBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar)
        again.apply(to: &data)
        XCTAssertEqual(data.entries[0].remainingAmount, result.rows[0].remaining, "Repeated sync must not charge the history twice")
    }

    func testReplaysLatestCorrectedCostAndOriginalAmountWithoutManualBaseline() throws {
        var data = fixture()
        data.entries[0].originalAmount = 6000
        data.costSyncStates?[.openAI]?.allocationCosts?[0] = CostBucket(start: date(0), end: date(2), cost: 900)
        data.providerLastCosts[.openAI]! -= 100
        let result = try HistoricalBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar)
        XCTAssertEqual(result.rows[0].remaining, Decimal(string: "2368.687844005"))
        XCTAssertEqual(result.remaining, Decimal(string: "7368.687844005"))
    }

    func testMissingOverlappingAndGrantCrossingPeriodsCannotOverwriteBalances() {
        for change in 0..<4 {
            var data = fixture()
            if change == 0 { data.costSyncStates?[.openAI]?.allocationCosts = nil }
            if change == 1 { data.costSyncStates?[.openAI]?.allocationCosts?[1] = CostBucket(start: date(1), end: date(4), cost: 400) }
            if change == 2 { data.entries[1].receivedAt = date(3) }
            if change == 3 { data.providerLastCosts[.openAI]! += 1 }
            let original = data.entries
            XCTAssertThrowsError(try HistoricalBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar))
            XCTAssertEqual(data.entries, original)
        }
    }

    func testOverspendBeforeNewGrantIsNotChargedToFutureFunds() throws {
        var data = fixture()
        data.costSyncStates?[.openAI]?.allocationCosts?[0] = CostBucket(start: date(0), end: date(2), cost: 6000)
        data.providerLastCosts[.openAI]! += 5000
        let result = try HistoricalBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar)
        XCTAssertEqual(result.rows[0].remaining, 0)
        XCTAssertEqual(result.uncoveredCost, 1200, "New money cannot retrospectively cover spend before its receipt")
        XCTAssertEqual(result.rows[2].remaining, Decimal(string: "2468.687844005"))
    }

    func testArchivedActiveOrMixedCurrencyGrantsRequireReview() {
        var data = fixture()
        data.entries[0].isArchived = true
        XCTAssertThrowsError(try HistoricalBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar))
        data = fixture()
        data.entries[0].unit = "TWD"
        XCTAssertThrowsError(try HistoricalBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar))
    }
}

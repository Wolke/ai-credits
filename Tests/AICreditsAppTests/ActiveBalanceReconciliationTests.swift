import XCTest
@testable import AICreditsApp

final class ActiveBalanceReconciliationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(_ day: Int) -> Date { Date(timeIntervalSince1970: Double(day) * 86_400) }
    private func fixture() -> AppData {
        let entries = [
            CreditEntry(platform: .openAI, originalAmount: 5000, remainingAmount: 5000,
                receivedAt: date(0), expiresAt: date(9), calculatesFromOriginal: true),
            CreditEntry(platform: .openAI, originalAmount: 5000, remainingAmount: 5000,
                receivedAt: date(4), expiresAt: date(20), calculatesFromOriginal: true),
            CreditEntry(platform: .openAI, originalAmount: 250, remainingAmount: 250,
                receivedAt: date(5), expiresAt: date(21), calculatesFromOriginal: true),
            CreditEntry(platform: .openAI, originalAmount: 1200, remainingAmount: 1200,
                receivedAt: date(1), expiresAt: date(3)),
            CreditEntry(platform: .openAI, originalAmount: 1200, remainingAmount: 1200,
                receivedAt: date(2), expiresAt: date(4)),
            CreditEntry(platform: .openAI, originalAmount: 300, remainingAmount: 300,
                receivedAt: date(10), expiresAt: date(30), calculatesFromOriginal: true)
        ]
        let cost = Decimal(string: "4131.312155995")!
        return AppData(entries: entries, providerLastCosts: [.openAI: cost], costSyncStates: [
            .openAI: CostSyncState(since: date(0), cumulativeCost: cost, currency: "USD", fetchedAt: date(6))
        ])
    }

    func testCurrentOriginalTotalMinusPeriodSpendIgnoresExpiredAndFutureGrants() throws {
        var data = fixture()
        let untouched = Array(data.entries[3...])
        let result = try ActiveBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar)
        XCTAssertEqual(result.originalTotal, 10250)
        XCTAssertEqual(result.remaining, Decimal(string: "6118.687844005"))
        XCTAssertEqual(result.rows.map(\.remaining), [Decimal(string: "868.687844005")!, 5000, 250])
        result.apply(to: &data)
        XCTAssertEqual(Array(data.entries[3...]), untouched)
        let again = try ActiveBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar)
        again.apply(to: &data)
        XCTAssertEqual(data.entries[0].remainingAmount, Decimal(string: "868.687844005"), "Repeating the calculation cannot deduct history twice")
    }

    func testOriginalEditsAndRefundsUseLatestCostsWithoutAnotherAPICall() throws {
        var data = fixture()
        data.entries[0].originalAmount = 6000
        data.providerLastCosts[.openAI]! -= 100
        let result = try ActiveBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar)
        XCTAssertEqual(result.remaining, Decimal(string: "7218.687844005"))
        XCTAssertEqual(result.rows[0].remaining, Decimal(string: "1968.687844005"))
    }

    func testExhaustedCurrentGrantRemainsPartOfOriginalPool() throws {
        var data = fixture()
        data.entries[0].remainingAmount = 0
        let result = try ActiveBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar)
        XCTAssertEqual(result.originalTotal, 10250)
        XCTAssertEqual(result.remaining, Decimal(string: "6118.687844005"))
        data.providerLastCosts[.openAI] = 11000
        let exhausted = try ActiveBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar)
        XCTAssertEqual(exhausted.remaining, 0)
        XCTAssertTrue(exhausted.rows.allSatisfy { $0.remaining == 0 })
        XCTAssertTrue(exhausted.formula.contains("-750"))
    }

    func testExpirationOrChangedReceiptRequiresMatchingCostPeriod() throws {
        var data = fixture()
        XCTAssertThrowsError(try ActiveBalanceReconciliation.calculate(for: .openAI, in: data, at: date(11), calendar: calendar))
        XCTAssertEqual(CostSynchronizer.startDate(for: .openAI, in: data, now: date(11), source: nil), date(4))
        data.entries[0].receivedAt = date(1)
        XCTAssertThrowsError(try ActiveBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar))
    }

    func testArchivedAndMixedCurrencyGrantsCannotInflateTotal() throws {
        var data = fixture()
        data.entries[1].isArchived = true
        let result = try ActiveBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar)
        XCTAssertEqual(result.originalTotal, 5250)
        XCTAssertEqual(result.remaining, Decimal(string: "1118.687844005"))
        data = fixture()
        data.entries[1].unit = "TWD"
        XCTAssertThrowsError(try ActiveBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar))
        data = fixture()
        data.entries[1].calculatesFromOriginal = false
        XCTAssertThrowsError(try ActiveBalanceReconciliation.calculate(for: .openAI, in: data, calendar: calendar))
    }
}

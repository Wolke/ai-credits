import XCTest
@testable import AICreditsApp

final class PlatformBalanceSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(original: Decimal, remaining: Decimal, expiresIn days: Int, unit: String = "USD") -> CreditEntry {
        CreditEntry(platform: .openAI, originalAmount: original, remainingAmount: remaining, unit: unit,
                    receivedAt: now.addingTimeInterval(-86_400 * 180), expiresAt: now.addingTimeInterval(86_400 * Double(days)))
    }

    func testOpenAIScreenshotTotalContainsThreeGrantsAndExcludesExpiredBalances() throws {
        let entries = [
            entry(original: 5000, remaining: 5000, expiresIn: 180),
            entry(original: Decimal(string: "4882.88")!, remaining: Decimal(string: "2199.92")!, expiresIn: 30),
            entry(original: 250, remaining: 250, expiresIn: 240),
            entry(original: 1200, remaining: Decimal(string: "1145.398478535")!, expiresIn: -90),
            entry(original: 1200, remaining: 1200, expiresIn: -60)
        ]
        let summary = try XCTUnwrap(PlatformBalanceSummary.all(in: entries, now: now).first)
        XCTAssertEqual(summary.remaining, Decimal(string: "7449.92"))
        XCTAssertEqual(summary.availableEntries.count, 3)
        XCTAssertEqual(summary.availableEntries.first?.remainingAmount, Decimal(string: "2199.92"))
        XCTAssertEqual(summary.expiredEntries.count, 2)
        XCTAssertTrue(summary.usesManualBaseline)
    }

    func testDifferentCurrenciesFutureAndArchivedGrantsCannotInflateTheTotal() {
        var future = entry(original: 3000, remaining: 3000, expiresIn: 200)
        future.receivedAt = now.addingTimeInterval(86_400)
        var archived = entry(original: 4000, remaining: 4000, expiresIn: 200)
        archived.isArchived = true
        let groups = PlatformBalanceSummary.all(in: [
            entry(original: 100, remaining: 80, expiresIn: 30),
            entry(original: 100, remaining: 20, expiresIn: 40, unit: "usd"),
            entry(original: 1000, remaining: 1000, expiresIn: 50, unit: "TWD"), future, archived
        ], now: now)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first { $0.currency == "USD" }?.remaining, 100)
        XCTAssertEqual(groups.first { $0.currency == "TWD" }?.remaining, 1000)
    }

    func testAllGrantsRemainAvailablePastTheFormerFiveRowLimit() throws {
        let entries = (1...8).map { entry(original: 10, remaining: 10, expiresIn: $0) }
        let summary = try XCTUnwrap(PlatformBalanceSummary.all(in: entries, now: now).first)
        XCTAssertEqual(summary.availableEntries.count, 8)
        XCTAssertEqual(summary.remaining, 80)
    }

    func testEnablingOriginalModeDoesNotPresentOldBalancesAsRecalculated() throws {
        var grant = entry(original: 5000, remaining: Decimal(string: "2199.92")!, expiresIn: 30)
        grant.calculatesFromOriginal = true
        var summary = try XCTUnwrap(PlatformBalanceSummary.all(in: [grant], now: now).first)
        XCTAssertTrue(summary.hasPendingCalculation)
        grant.remainingAmount = 868
        grant.syncBaselineCost = 4132
        summary = try XCTUnwrap(PlatformBalanceSummary.all(in: [grant], now: now).first)
        XCTAssertFalse(summary.hasPendingCalculation)
    }
}

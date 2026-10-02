import XCTest
@testable import AICreditsApp

final class ElevenLabsUSDValuationTests: XCTestCase {
    func testCreditValueUsesConfiguredRatioAndKeepsFractionalDollars() {
        let value = ElevenLabsUSDValuation(credits: 1_000_000, usd: 100)
        XCTAssertEqual(value.estimate(for: 329_315), Decimal(string: "32.9315"))
        XCTAssertEqual(value.estimate(for: 0), 0)
        XCTAssertEqual(value.estimate(for: 2_000_000), 200, "A credit rollover must use the same configured unit value")
    }

    func testInvalidOrMissingValuationNeverInventsADollarBalance() throws {
        for value in [ElevenLabsUSDValuation(credits: 0, usd: 100), .init(credits: 100, usd: -1), .init(credits: .nan, usd: 100)] {
            XCTAssertFalse(value.isValid)
            XCTAssertNil(value.estimate(for: 100))
        }
        XCTAssertNil(ElevenLabsUSDValuation(credits: 100, usd: 10).estimate(for: -1))
        let legacy = Data(#"{"entries":[],"providerLastCosts":[],"deliveredNotifications":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AppData.self, from: legacy).elevenLabsUSDValuation)
    }

    func testAPISyncAndResetPreserveUserValuationAndRawCreditUnits() throws {
        let value = ElevenLabsUSDValuation(credits: 1000, usd: 10)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var data = AppData(elevenLabsUSDValuation: value)
        CostSynchronizer.apply(ElevenLabsBalance(limit: 1000, used: 300, resetsAt: now.addingTimeInterval(86_400), tier: "grant", fetchedAt: now), to: &data)
        XCTAssertEqual(data.entries[0].remainingAmount, 700)
        XCTAssertEqual(data.entries[0].unit, "credits")
        XCTAssertEqual(data.elevenLabsUSDValuation?.estimate(for: data.entries[0].remainingAmount), 7)
        CostSynchronizer.apply(ElevenLabsBalance(limit: 2000, used: 0, resetsAt: now.addingTimeInterval(2 * 86_400), tier: "grant", fetchedAt: now), to: &data)
        XCTAssertEqual(data.elevenLabsUSDValuation, value)
        XCTAssertEqual(data.elevenLabsUSDValuation?.estimate(for: data.entries[0].remainingAmount), 20)
        let restored = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(restored.elevenLabsUSDValuation, value)
        XCTAssertEqual(restored.entries[0].remainingAmount, 2000)
    }
}

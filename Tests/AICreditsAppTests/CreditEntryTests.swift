import XCTest
@testable import AICreditsApp

final class CreditEntryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testUrgencyBoundaries() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 28)))
        XCTAssertEqual(entry(days: 31, now: now).urgency(now: now, calendar: calendar), .normal)
        XCTAssertEqual(entry(days: 30, now: now).urgency(now: now, calendar: calendar), .warning)
        XCTAssertEqual(entry(days: 7, now: now).urgency(now: now, calendar: calendar), .critical)
        XCTAssertEqual(entry(days: -1, now: now).urgency(now: now, calendar: calendar), .expired)
    }

    func testEmptyBalanceIsExpired() throws {
        var value = entry(days: 90, now: .now)
        value.remainingAmount = 0
        XCTAssertEqual(value.urgency(), .expired)
    }

    func testMonthlyGrantSeriesCreatesIndependentExpiringEntries() throws {
        var template = CreditEntry()
        template.platform = .lovable
        template.name = "Lovable monthly credits"
        template.originalAmount = 1_200
        template.remainingAmount = 0
        template.receivedAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 14)))

        let entries = CreditEntry.monthlyGrantSeries(
            from: template,
            count: 12,
            validityMonths: 2,
            calendar: calendar
        )

        XCTAssertEqual(entries.count, 12)
        XCTAssertEqual(Set(entries.map(\.id)).count, 12)
        XCTAssertTrue(entries.allSatisfy { $0.originalAmount == 1_200 && $0.remainingAmount == 1_200 })
        XCTAssertEqual(calendar.dateComponents([.month], from: entries[0].receivedAt, to: entries[0].expiresAt).month, 2)
        XCTAssertEqual(calendar.component(.month, from: entries[0].receivedAt), 4)
        XCTAssertEqual(calendar.component(.month, from: entries[11].receivedAt), 3)
        XCTAssertEqual(calendar.component(.year, from: entries[11].receivedAt), 2027)
    }

    private func entry(days: Int, now: Date) -> CreditEntry {
        var value = CreditEntry()
        value.originalAmount = 100
        value.remainingAmount = 50
        value.expiresAt = calendar.date(byAdding: .day, value: days, to: now)!
        return value
    }
}

import XCTest
@testable import AICreditsApp

final class CreditAllocatorTests: XCTestCase {
    func testDeductsEarliestExpirationFirst() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var early = CreditEntry(platform: .openAI, name: "Early", originalAmount: 10, remainingAmount: 10, unit: "USD", receivedAt: now, expiresAt: now.addingTimeInterval(86_400), notes: "")
        var later = CreditEntry(platform: .openAI, name: "Later", originalAmount: 20, remainingAmount: 20, unit: "USD", receivedAt: now, expiresAt: now.addingTimeInterval(172_800), notes: "")
        early.id = UUID(); later.id = UUID()
        var entries = [later, early]

        CreditAllocator.deduct(15, platform: .openAI, currency: "USD", fetchedAt: now, from: &entries)

        XCTAssertEqual(entries.first(where: { $0.name == "Early" })?.remainingAmount, 0)
        XCTAssertEqual(entries.first(where: { $0.name == "Later" })?.remainingAmount, 15)
    }

    func testDoesNotDeductOtherPlatformOrUnit() {
        let now = Date.now
        var entries = [
            CreditEntry(platform: .claude, name: "Claude", originalAmount: 10, remainingAmount: 10, unit: "USD", receivedAt: now, expiresAt: now, notes: ""),
            CreditEntry(platform: .openAI, name: "Tokens", originalAmount: 100, remainingAmount: 100, unit: "tokens", receivedAt: now, expiresAt: now, notes: "")
        ]
        CreditAllocator.deduct(5, platform: .openAI, currency: "USD", fetchedAt: now, from: &entries)
        XCTAssertEqual(entries.map(\.remainingAmount), [10, 100])
    }

    func testDoesNotDeductCreditBeforeItsGrantDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = CreditEntry(
            platform: .lovable,
            name: "Next month",
            originalAmount: 1_200,
            remainingAmount: 1_200,
            unit: "USD",
            receivedAt: now.addingTimeInterval(86_400),
            expiresAt: now.addingTimeInterval(86_400 * 60),
            notes: ""
        )
        var entries = [future]

        CreditAllocator.deduct(100, platform: .lovable, currency: "USD", fetchedAt: now, from: &entries)

        XCTAssertEqual(entries[0].remainingAmount, 1_200)
    }
}

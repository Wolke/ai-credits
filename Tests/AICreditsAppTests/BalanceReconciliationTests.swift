import XCTest
@testable import AICreditsApp

final class BalanceReconciliationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() -> AppData {
        let entry = CreditEntry(platform: .claude, originalAmount: 5000,
            remainingAmount: Decimal(string: "4968.74746695")!, receivedAt: start,
            expiresAt: start.addingTimeInterval(86_400 * 180))
        let state = CostSyncState(since: start, cumulativeCost: Decimal(string: "4425.8102765")!,
            currency: "USD", fetchedAt: start.addingTimeInterval(86_400))
        return AppData(entries: [entry], costSyncStates: [.claude: state])
    }

    func testHistoricalCorrectionThenRepeatedSyncDoesNotDoubleCharge() throws {
        var data = fixture()
        let proposal = try XCTUnwrap(BalanceReconciliation.preview(for: .claude, in: data))
        XCTAssertEqual(proposal.remaining, Decimal(string: "574.1897235"))
        try proposal.apply(to: &data)
        let state = proposal.state
        let same = ProviderUsage(platform: .claude, cumulativeCost: state.cumulativeCost, currency: "USD", fetchedAt: state.fetchedAt)
        XCTAssertEqual(CostSynchronizer.apply(same, since: start, source: nil, to: &data), 0)
        XCTAssertEqual(data.entries[0].remainingAmount, proposal.remaining)
        let increased = ProviderUsage(platform: .claude, cumulativeCost: state.cumulativeCost + 10, currency: "USD", fetchedAt: state.fetchedAt.addingTimeInterval(60))
        XCTAssertEqual(CostSynchronizer.apply(increased, since: start, source: nil, to: &data), 10)
        XCTAssertEqual(data.entries[0].remainingAmount, Decimal(string: "564.1897235"))
    }

    func testAmbiguousMultipleGrantsAndMismatchedDatesHaveNoAutomaticCorrection() {
        var data = fixture()
        data.entries.append(CreditEntry(platform: .claude, originalAmount: 100, remainingAmount: 100, receivedAt: start))
        XCTAssertNil(BalanceReconciliation.preview(for: .claude, in: data))
        data.entries[1].isArchived = true
        XCTAssertNil(BalanceReconciliation.preview(for: .claude, in: data), "Archived grants may already have paid part of the cost")
        data = fixture()
        data.entries[0].receivedAt = start.addingTimeInterval(-86_400)
        XCTAssertNil(BalanceReconciliation.preview(for: .claude, in: data))
        data = fixture()
        data.entries[0].unit = "TWD"
        XCTAssertNil(BalanceReconciliation.preview(for: .claude, in: data))
    }

    func testEditedBalanceOrNewUsageInvalidatesPreview() throws {
        var data = fixture()
        let proposal = try XCTUnwrap(BalanceReconciliation.preview(for: .claude, in: data))
        data.entries[0].remainingAmount = 300
        XCTAssertThrowsError(try proposal.apply(to: &data))
        XCTAssertEqual(data.entries[0].remainingAmount, 300)
        data = fixture()
        data.costSyncStates?[.claude]?.cumulativeCost += 1
        XCTAssertThrowsError(try proposal.apply(to: &data))
    }

    func testOverdrawnCreditIsClampedAndOtherPlatformsRemainUnchanged() throws {
        var data = fixture()
        data.costSyncStates?[.claude]?.cumulativeCost = 6000
        let other = CreditEntry(platform: .elevenLabs, originalAmount: 1000, remainingAmount: 750)
        data.entries.append(other)
        let proposal = try XCTUnwrap(BalanceReconciliation.preview(for: .claude, in: data))
        try proposal.apply(to: &data)
        XCTAssertEqual(data.entries[0].remainingAmount, 0)
        XCTAssertEqual(data.entries[1], other)
        XCTAssertNil(BalanceReconciliation.preview(for: .elevenLabs, in: data))
    }

    func testCorrectionSurvivesSaveAndReload() throws {
        var data = fixture()
        let proposal = try XCTUnwrap(BalanceReconciliation.preview(for: .claude, in: data))
        try proposal.apply(to: &data)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceService(fileURL: directory.appending(path: "credits.json"))
        try persistence.save(data)
        let restored = try persistence.load()
        XCTAssertEqual(restored.entries[0].remainingAmount, proposal.remaining)
        XCTAssertEqual(restored.entries[0].syncBaselineCost, proposal.state.cumulativeCost)
        XCTAssertEqual(restored.costSyncStates?[.claude], proposal.state)
    }
}

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
        XCTAssertTrue(restored.entries[0].usesOriginalCostBalance)
    }

    func testOriginalBalanceReplacesIncorrectLegacyRemainingOnEverySync() {
        var data = fixture()
        data.entries[0].calculatesFromOriginal = true
        let fetchedAt = start.addingTimeInterval(86_400)
        for cost in [4428, 4428, 4430] {
            let usage = ProviderUsage(platform: .claude, cumulativeCost: Decimal(cost), currency: "USD", fetchedAt: fetchedAt)
            CostSynchronizer.apply(usage, since: start, source: nil, to: &data)
            XCTAssertEqual(data.entries[0].remainingAmount, 5000 - Decimal(cost))
            XCTAssertEqual(data.entries[0].syncBaselineCost, Decimal(cost))
        }
    }

    func testOriginalBalanceUsesLatestAPIValueIncludingDownwardCorrections() {
        var data = fixture()
        data.entries[0].calculatesFromOriginal = true
        for cost in [4428, 4400, 4420, 4428] {
            let usage = ProviderUsage(platform: .claude, cumulativeCost: Decimal(cost), currency: "USD", fetchedAt: start.addingTimeInterval(86_400))
            CostSynchronizer.apply(usage, since: start, source: nil, to: &data)
            XCTAssertEqual(data.entries[0].remainingAmount, 5000 - Decimal(cost))
        }
    }

    func testOriginalCalculationDoesNotAssignAggregateCostToMultipleGrants() {
        var data = fixture()
        data.entries[0].calculatesFromOriginal = true
        var other = data.entries[0]
        other.id = UUID()
        data.entries.append(other)
        let unchanged = data.entries
        let usage = ProviderUsage(platform: .claude, cumulativeCost: 4428, currency: "USD", fetchedAt: start.addingTimeInterval(86_400))
        CostSynchronizer.apply(usage, since: start, source: nil, to: &data)
        XCTAssertEqual(data.entries, unchanged)
    }

    func testReturningToManualModeAfterAPICorrectionUsesLatestBaseline() {
        var data = fixture()
        data.entries[0].calculatesFromOriginal = true
        let fetchedAt = start.addingTimeInterval(86_400)
        CostSynchronizer.apply(ProviderUsage(platform: .claude, cumulativeCost: 4400, currency: "USD", fetchedAt: fetchedAt), since: start, source: nil, to: &data)
        data.entries[0].calculatesFromOriginal = false
        CostSynchronizer.apply(ProviderUsage(platform: .claude, cumulativeCost: 4410, currency: "USD", fetchedAt: fetchedAt), since: start, source: nil, to: &data)
        XCTAssertEqual(data.entries[0].remainingAmount, 590)
    }

    func testChangedGrantDateRequiresMatchingAPIPeriod() {
        var data = fixture()
        data.entries[0].calculatesFromOriginal = true
        let newStart = start.addingTimeInterval(-86_400)
        data.entries[0].receivedAt = newStart
        XCTAssertEqual(CostSynchronizer.startDate(for: .claude, in: data, now: start, source: nil), newStart)
        XCTAssertNil(CostSynchronizer.recalculateOriginalBalance(for: .claude, in: &data))
        let usage = ProviderUsage(platform: .claude, cumulativeCost: 4428, currency: "USD", fetchedAt: start.addingTimeInterval(86_400))
        CostSynchronizer.apply(usage, since: newStart, source: nil, to: &data)
        XCTAssertEqual(data.entries[0].remainingAmount, 572)
    }

    func testOverdrawnFormulaShowsActualDifferenceAndZeroCredit() throws {
        var data = fixture()
        data.costSyncStates?[.claude]?.cumulativeCost = 6000
        let proposal = try XCTUnwrap(BalanceReconciliation.preview(for: .claude, in: data))
        try proposal.apply(to: &data)
        XCTAssertEqual(data.entries[0].remainingAmount, 0)
        XCTAssertTrue(data.entries[0].balanceFormula?.contains(Decimal(-1000).formatted(.number.precision(.fractionLength(0...2)))) == true)
        XCTAssertTrue(data.entries[0].balanceFormula?.contains("額度已用完，剩餘 0") == true)
    }
}

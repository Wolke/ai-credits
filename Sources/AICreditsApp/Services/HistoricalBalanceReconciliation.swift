import Foundation

/// Replays costs while grant eligibility is constant. Aggregate lifetime cost alone
/// cannot tell how much was paid by grants which have since expired.
struct HistoricalBalanceReconciliation {
    struct Row {
        let entry: CreditEntry
        let spent: Decimal
        let remaining: Decimal
    }

    let platform: CreditPlatform
    let state: CostSyncState
    let cost: Decimal
    let rows: [Row]
    let uncoveredCost: Decimal
    let expiredUnused: Decimal
    let remaining: Decimal

    static func grants(for platform: CreditPlatform, in data: AppData, at date: Date) -> [CreditEntry] {
        data.entries.filter { $0.platform == platform && !$0.isAutomaticSubscription && $0.receivedAt <= date }
    }

    static func isEnabled(for platform: CreditPlatform, in data: AppData, at date: Date) -> Bool {
        let entries = grants(for: platform, in: data, at: date)
        return platform == .openAI && entries.count > 1 && entries.allSatisfy(\.usesOriginalCostBalance)
    }

    static func expirationBoundary(_ entry: CreditEntry, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: entry.expiresAt)) ?? entry.expiresAt
    }

    static func receiptBoundary(_ entry: CreditEntry) -> Date {
        Date(timeIntervalSince1970: floor(entry.receivedAt.timeIntervalSince1970))
    }

    static func boundaries(for entries: [CreditEntry], calendar: Calendar = .current) -> [Date] {
        Array(Set(entries.flatMap { [receiptBoundary($0), expirationBoundary($0, calendar: calendar)] })).sorted()
    }

    static func calculate(for platform: CreditPlatform, in data: AppData, calendar: Calendar = .current) throws -> Self {
        guard platform == .openAI, let state = data.costSyncStates?[platform],
              let periods = state.allocationCosts else { throw HistoryError.missingPeriods }
        let entries = grants(for: platform, in: data, at: state.fetchedAt)
        guard entries.count > 1, entries.map(receiptBoundary).min() == state.since,
              entries.allSatisfy({ $0.originalAmount >= 0 && $0.unit.caseInsensitiveCompare(state.currency) == .orderedSame
                  && (!$0.isArchived || expirationBoundary($0, calendar: calendar) <= state.fetchedAt) }) else {
            throw HistoryError.invalidGrants
        }
        let cost = data.providerLastCosts[platform] ?? state.cumulativeCost
        guard cost >= 0, periods.reduce(Decimal.zero, { $0 + $1.cost }) == cost else { throw HistoryError.inconsistentPeriods }
        let sorted = periods.sorted { $0.start < $1.start }
        var cursor = state.since
        let boundaries = boundaries(for: entries, calendar: calendar)
        var balances = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.originalAmount) })
        var uncovered: Decimal = 0
        for period in sorted {
            guard period.start == cursor, period.end > period.start, period.end <= state.fetchedAt,
                  period.cost >= 0, !boundaries.contains(where: { $0 > period.start && $0 < period.end }) else {
                throw HistoryError.inconsistentPeriods
            }
            cursor = period.end
            var pending = period.cost
            let eligible = entries.filter {
                receiptBoundary($0) <= period.start && expirationBoundary($0, calendar: calendar) >= period.end
            }.sorted {
                if $0.expiresAt != $1.expiresAt { return $0.expiresAt < $1.expiresAt }
                if $0.receivedAt != $1.receivedAt { return $0.receivedAt < $1.receivedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            for entry in eligible {
                let deduction = min(balances[entry.id] ?? 0, pending)
                balances[entry.id, default: 0] -= deduction
                pending -= deduction
            }
            uncovered += pending
        }
        guard cursor == state.fetchedAt else { throw HistoryError.inconsistentPeriods }
        let rows = entries.map { Row(entry: $0, spent: $0.originalAmount - balances[$0.id, default: 0], remaining: balances[$0.id, default: 0]) }
        let expiredUnused = rows.filter { expirationBoundary($0.entry, calendar: calendar) <= state.fetchedAt }.reduce(Decimal.zero) { $0 + $1.remaining }
        let remaining = rows.filter { expirationBoundary($0.entry, calendar: calendar) > state.fetchedAt && !$0.entry.isArchived }.reduce(Decimal.zero) { $0 + $1.remaining }
        return Self(platform: platform, state: state, cost: cost, rows: rows, uncoveredCost: uncovered,
                    expiredUnused: expiredUnused, remaining: remaining)
    }

    func apply(to data: inout AppData) {
        for row in rows {
            guard let index = data.entries.firstIndex(where: { $0.id == row.entry.id }) else { continue }
            data.entries[index].remainingAmount = row.remaining
            data.entries[index].syncBaselineCost = row.spent
            data.entries[index].syncBaselineAt = state.fetchedAt
            data.entries[index].lastSyncedAt = state.fetchedAt
        }
        data.costSyncStates?[platform]?.cumulativeCost = cost
    }
}

enum HistoryError: LocalizedError {
    case missingPeriods, invalidGrants, inconsistentPeriods
    var errorDescription: String? {
        switch self {
        case .missingPeriods: "多筆額度尚缺完整期間的花費明細，請立即同步；此次保留原有餘額。"
        case .invalidGrants: "原始額度、幣別或花費期間不一致，無法分攤歷史花費；請檢查各筆額度。"
        case .inconsistentPeriods: "分段花費與累計花費或額度期間尚未對齊（帳務可能更新中），此次保留原有餘額；請重新同步。"
        }
    }
}

import Foundation

/// Estimates the current pool: unexpired original grants minus costs since the
/// earliest current grant. Expired grants do not offset this period's spending.
struct ActiveBalanceReconciliation {
    struct Row {
        let entry: CreditEntry
        let spent: Decimal
        let remaining: Decimal
    }

    let platform: CreditPlatform
    let state: CostSyncState
    let cost: Decimal
    let rows: [Row]
    var originalTotal: Decimal { rows.reduce(0) { $0 + $1.entry.originalAmount } }
    var remaining: Decimal { max(0, originalTotal - cost) }
    var formula: String {
        let difference = originalTotal - cost
        let text = "\(originalTotal.formatted()) − \(cost.formatted()) = \(difference.formatted()) \(state.currency)"
        return difference < 0 ? text + "（額度已用完，剩餘 0）" : text
    }

    static func grants(for platform: CreditPlatform, in data: AppData, at date: Date, calendar: Calendar = .current) -> [CreditEntry] {
        data.entries.filter {
            $0.platform == platform && !$0.isArchived && !$0.isAutomaticSubscription
                && $0.receivedAt <= date && $0.daysUntilExpiration(now: date, calendar: calendar) >= 0
        }
    }

    static func isEnabled(for platform: CreditPlatform, in data: AppData, at date: Date) -> Bool {
        let entries = grants(for: platform, in: data, at: date)
        return platform == .openAI && !entries.isEmpty && entries.allSatisfy(\.usesOriginalCostBalance)
    }

    static func receiptBoundary(_ entry: CreditEntry) -> Date {
        Date(timeIntervalSince1970: floor(entry.receivedAt.timeIntervalSince1970))
    }

    static func calculate(for platform: CreditPlatform, in data: AppData, at date: Date? = nil, calendar: Calendar = .current) throws -> Self {
        guard platform == .openAI, let state = data.costSyncStates?[platform] else { throw ActiveBalanceError.missingCosts }
        let entries = grants(for: platform, in: data, at: date ?? state.fetchedAt, calendar: calendar)
        guard !entries.isEmpty, entries.allSatisfy({ $0.usesOriginalCostBalance && $0.originalAmount >= 0
            && $0.unit.caseInsensitiveCompare(state.currency) == .orderedSame }) else { throw ActiveBalanceError.invalidGrants }
        guard entries.map(receiptBoundary).min() == state.since, state.fetchedAt >= state.since else {
            throw ActiveBalanceError.changedPeriod
        }
        let cost = data.providerLastCosts[platform] ?? state.cumulativeCost
        guard cost >= 0 else { throw ActiveBalanceError.invalidGrants }
        var pending = cost
        // The pool's cost is applied once, in expiration order, to display each row.
        let rows = entries.sorted {
            if $0.expiresAt != $1.expiresAt { return $0.expiresAt < $1.expiresAt }
            if $0.receivedAt != $1.receivedAt { return $0.receivedAt < $1.receivedAt }
            return $0.id.uuidString < $1.id.uuidString
        }.map { entry in
            let spent = min(entry.originalAmount, pending)
            pending -= spent
            return Row(entry: entry, spent: spent, remaining: entry.originalAmount - spent)
        }
        return Self(platform: platform, state: state, cost: cost, rows: rows)
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

enum ActiveBalanceError: LocalizedError {
    case missingCosts, invalidGrants, changedPeriod
    var errorDescription: String? {
        switch self {
        case .missingCosts: "尚無 API 花費資料，請立即同步；此次保留原有餘額。"
        case .invalidGrants: "請確認有效額度的原始金額、幣別，並全部開啟自動計算；此次保留原有餘額。"
        case .changedPeriod: "有效額度的花費起算日已變更，請重新同步對應期間的花費；此次保留原有餘額。"
        }
    }
}

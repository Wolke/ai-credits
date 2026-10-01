import Foundation

struct BalanceReconciliation: Identifiable, Equatable {
    let entry: CreditEntry
    let state: CostSyncState
    let cost: Decimal
    var id: UUID { entry.id }
    var remaining: Decimal { max(0, entry.originalAmount - cost) }

    static func preview(for platform: CreditPlatform, in data: AppData) -> Self? {
        guard platform.usesCostEstimates, let state = data.costSyncStates?[platform],
              state.cumulativeCost >= 0 else { return nil }
        // Aggregate cost cannot reliably reconstruct allocation across several grants or periods.
        let grants = data.entries.filter {
            $0.platform == platform && !$0.isAutomaticSubscription
                && $0.receivedAt <= state.fetchedAt
                && $0.unit.caseInsensitiveCompare(state.currency) == .orderedSame
        }
        guard grants.count == 1, let entry = grants.first, !entry.isArchived,
              entry.originalAmount >= 0, entry.receivedAt == state.since,
              entry.daysUntilExpiration(now: state.fetchedAt) >= 0 else { return nil }
        return Self(entry: entry, state: state, cost: max(0, data.providerLastCosts[platform] ?? state.cumulativeCost))
    }

    func apply(to data: inout AppData) throws {
        guard Self.preview(for: entry.platform, in: data) == self,
              let index = data.entries.firstIndex(where: { $0.id == entry.id }) else {
            throw ReconciliationError.changed
        }
        data.entries[index].remainingAmount = remaining
        data.entries[index].calculatesFromOriginal = true
        data.entries[index].syncBaselineAt = state.fetchedAt
        data.entries[index].syncBaselineCost = cost
        data.entries[index].lastSyncedAt = state.fetchedAt
        // This balance includes the latest total, including refunds. If switched back to
        // manual mode, future deductions must start from this same total.
        data.costSyncStates?[entry.platform]?.cumulativeCost = cost
        // Subsequent refreshes recompute from the original grant, never from this remaining value.
    }
}

enum ReconciliationError: LocalizedError {
    case changed
    var errorDescription: String? {
        "額度、帳務或設定已變更，請關閉此視窗，重新同步並檢查校正金額。"
    }
}

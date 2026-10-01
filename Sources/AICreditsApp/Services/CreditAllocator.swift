import Foundation

enum CreditAllocator {
    static func deduct(
        _ amount: Decimal,
        platform: CreditPlatform,
        currency: String,
        fetchedAt: Date,
        from entries: inout [CreditEntry]
    ) {
        var remainingCost = max(0, amount)
        let indices = entries.indices.filter {
            !entries[$0].isArchived && entries[$0].platform == platform
                && entries[$0].remainingAmount > 0
                && entries[$0].receivedAt <= fetchedAt
                && entries[$0].unit.caseInsensitiveCompare(currency) == .orderedSame
        }.sorted { entries[$0].expiresAt < entries[$1].expiresAt }

        for index in indices {
            guard remainingCost > 0 else { break }
            let deduction = min(entries[index].remainingAmount, remainingCost)
            entries[index].remainingAmount -= deduction
            remainingCost -= deduction
        }
        for index in indices {
            entries[index].lastSyncedAt = fetchedAt
            entries[index].syncBaselineAt = entries[index].syncBaselineAt ?? fetchedAt
        }
    }
}

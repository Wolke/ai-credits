import Foundation

enum CostSynchronizer {
    static func startDate(for platform: CreditPlatform, in data: AppData, now: Date, source: String?) -> Date {
        if let state = data.costSyncStates?[platform], state.source == source { return state.since }
        // Once established, this start date stays fixed even when a grant is exhausted or removed.
        return data.entries.filter { !$0.isArchived && $0.platform == platform && $0.receivedAt <= now }
            .map(\.receivedAt).min() ?? now.addingTimeInterval(-30 * 86_400)
    }

    static func apply(_ usage: ProviderUsage, since: Date, source: String?, to data: inout AppData) {
        let previous = data.costSyncStates?[usage.platform]
        let comparable = previous?.since == since && previous?.currency == usage.currency && previous?.source == source
        // Legacy totals may contain only one API page. Rebaseline once without charging historical usage again.
        let delta = comparable ? max(0, usage.cumulativeCost - (previous?.cumulativeCost ?? usage.cumulativeCost)) : 0
        // A downward correction must not cause the same usage to be charged again when totals recover.
        let baselineCost = comparable ? max(previous?.cumulativeCost ?? 0, usage.cumulativeCost) : usage.cumulativeCost
        if data.costSyncStates == nil { data.costSyncStates = [:] }
        data.costSyncStates?[usage.platform] = CostSyncState(
            since: since, cumulativeCost: baselineCost, currency: usage.currency,
            fetchedAt: usage.fetchedAt, source: source
        )
        data.providerLastCosts[usage.platform] = usage.cumulativeCost
        CreditAllocator.deduct(delta, platform: usage.platform, currency: usage.currency, fetchedAt: usage.fetchedAt, from: &data.entries)
    }

    static func apply(_ balance: ElevenLabsBalance, to data: inout AppData) {
        let index = data.entries.firstIndex { $0.platform == .elevenLabs && $0.isAutomaticSubscription && !$0.isArchived }
        var entry = index.map { data.entries[$0] } ?? CreditEntry(platform: .elevenLabs, receivedAt: balance.fetchedAt)
        if entry.subscriptionResetsAt != balance.resetsAt {
            entry.receivedAt = balance.fetchedAt
            data.deliveredNotifications = data.deliveredNotifications.filter { !$0.hasPrefix(entry.id.uuidString + "-") }
        }
        entry.name = "\(balance.tier.capitalized) 方案"
        entry.originalAmount = balance.limit
        entry.remainingAmount = balance.remaining
        entry.unit = "credits"
        entry.isSubscriptionBalance = true
        entry.subscriptionResetsAt = balance.resetsAt
        entry.expiresAt = balance.resetsAt ?? .distantFuture
        entry.lastSyncedAt = balance.fetchedAt
        if let index { data.entries[index] = entry } else { data.entries.append(entry) }
    }
}

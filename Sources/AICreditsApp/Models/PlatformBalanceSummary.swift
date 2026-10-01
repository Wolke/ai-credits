import Foundation

/// Shared by the menu, management window and settings so their totals have the same scope.
struct PlatformBalanceSummary: Identifiable {
    let platform: CreditPlatform
    let currency: String
    let entries: [CreditEntry]
    let now: Date

    var id: String { platform.rawValue + ":" + currency }
    var availableEntries: [CreditEntry] {
        entries.filter { $0.isAutomaticSubscription || ($0.remainingAmount > 0 && $0.daysUntilExpiration(now: now) >= 0) }
    }
    var expiredEntries: [CreditEntry] { entries.filter { !$0.isAutomaticSubscription && $0.daysUntilExpiration(now: now) < 0 } }
    var remaining: Decimal { availableEntries.reduce(0) { $0 + $1.remainingAmount } }
    var usesManualBaseline: Bool { platform.usesCostEstimates && availableEntries.contains { !$0.usesOriginalCostBalance } }
    var sumFormula: String {
        availableEntries.map { $0.remainingAmount.formatted() }.joined(separator: " + ") + " = \(remaining.formatted()) \(currency)"
    }

    static func all(in entries: [CreditEntry], now: Date = .now) -> [Self] {
        let issued = entries.filter { !$0.isArchived && $0.receivedAt <= now }
        var groups: [Self] = []
        var seen = Set<String>()
        for entry in issued {
            let unit = entry.unit.uppercased()
            let id = entry.platform.rawValue + ":" + unit
            guard seen.insert(id).inserted else { continue }
            let matching = issued.filter { $0.platform == entry.platform && $0.unit.uppercased() == unit }
                .sorted {
                    if $0.expiresAt != $1.expiresAt { return $0.expiresAt < $1.expiresAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
            groups.append(Self(platform: entry.platform, currency: unit, entries: matching, now: now))
        }
        return groups.sorted {
            let left = $0.availableEntries.first?.expiresAt ?? .distantFuture
            let right = $1.availableEntries.first?.expiresAt ?? .distantFuture
            return left == right ? $0.id < $1.id : left < right
        }
    }
}

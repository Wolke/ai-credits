import Foundation

struct AppData: Codable, Sendable {
    var entries: [CreditEntry] = []
    var deliveredNotifications: Set<String> = []
    var providerLastCosts: [CreditPlatform: Decimal] = [:]
    var lastRefreshAt: Date?
    var lastRefreshError: String?
    var costSyncStates: [CreditPlatform: CostSyncState]?
    var providerSyncStatuses: [CreditPlatform: ProviderSyncStatus]?
    var syncEvents: [SyncEvent]?
}

struct CostSyncState: Codable, Equatable, Sendable {
    var since: Date
    var cumulativeCost: Decimal
    var currency: String
    var fetchedAt: Date
    var source: String?
    var costBuckets: [CostBucket]?
}

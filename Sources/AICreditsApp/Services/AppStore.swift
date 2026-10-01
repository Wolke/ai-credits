import Foundation
import Combine
import AppKit

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var data: AppData
    @Published private(set) var isRefreshing = false
    @Published private(set) var providerStatuses: [CreditPlatform: ProviderSyncStatus] = [:]

    private let persistence: PersistenceService
    private let keychain: any CredentialStore
    private let notifications: NotificationService
    private let client: BillingHTTPClient
    private let now: @Sendable () -> Date
    private var refreshTimer: Timer?
    private var wakeObserver: AnyCancellable?
    private var refreshTasks: [CreditPlatform: (revision: Int, source: String?, task: Task<Void, Never>)] = [:]
    private var credentialRevisions: [CreditPlatform: Int] = [:]
    private var lastAttempts: [CreditPlatform: Date] = [:]

    init(
        persistence: PersistenceService = PersistenceService(),
        keychain: any CredentialStore = KeychainService(),
        notifications: NotificationService = NotificationService(),
        client: BillingHTTPClient = BillingHTTPClient(),
        now: @escaping @Sendable () -> Date = { .now },
        automaticallyRefresh: Bool = true
    ) {
        self.persistence = persistence
        self.keychain = keychain
        self.notifications = notifications
        self.client = client
        self.now = now
        self.data = (try? persistence.load()) ?? AppData()
        if automaticallyRefresh { scheduleRefresh() }
    }

    var activeEntries: [CreditEntry] {
        data.entries.filter { !$0.isArchived }.sorted {
            let left = $0.urgency(), right = $1.urgency()
            if left != right { return left < right }
            return $0.expiresAt < $1.expiresAt
        }
    }

    var issuedEntries: [CreditEntry] {
        activeEntries.filter { $0.receivedAt <= Date.now }
    }

    var currentEntries: [CreditEntry] {
        issuedEntries.filter { $0.isAutomaticSubscription || $0.urgency() != .expired }
    }

    var nearestEntry: CreditEntry? { currentEntries.first { $0.hasKnownExpiration } }

    func upsert(_ entry: CreditEntry) {
        if let index = data.entries.firstIndex(where: { $0.id == entry.id }) {
            data.entries[index] = entry
        } else {
            data.entries.append(entry)
        }
        saveAndCheckNotifications()
    }

    func archive(id: UUID) {
        guard let index = data.entries.firstIndex(where: { $0.id == id }) else { return }
        data.entries[index].isArchived = true
        save()
    }

    func delete(id: UUID) {
        data.entries.removeAll { $0.id == id }
        data.deliveredNotifications = data.deliveredNotifications.filter {
            !$0.hasPrefix(id.uuidString + "-")
        }
        save()
    }

    func quickUpdate(id: UUID, remaining: Decimal) {
        guard let index = data.entries.firstIndex(where: { $0.id == id }) else { return }
        data.entries[index].remainingAmount = max(0, remaining)
        saveAndCheckNotifications()
    }

    func setAPIKey(_ key: String, for platform: CreditPlatform) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = try keychain.get(for: platform, allowInteraction: true)
        if trimmed.isEmpty {
            try keychain.delete(for: platform)
        } else {
            try keychain.set(trimmed, for: platform)
        }
        if trimmed != previous {
            credentialRevisions[platform, default: 0] += 1
            data.costSyncStates?[platform] = nil
            data.providerLastCosts[platform] = nil
        }
        providerStatuses[platform] = .notConfigured(trimmed.isEmpty ? platform.credentialHint : "金鑰已儲存，等待同步")
        lastAttempts[platform] = nil
        updateRefreshError()
        save()
    }

    func refresh() async {
        await refresh(platforms: CreditPlatform.allCases.filter(\.supportsAutomaticSync), allowInteraction: true)
    }

    func refresh(platform: CreditPlatform) async {
        await refresh(platform: platform, allowInteraction: true)
    }

    func refreshIfNeeded() async {
        // Publishing also refreshes day counters after midnight or sleep, without a successful API call.
        objectWillChange.send()
        let due = CreditPlatform.allCases.filter {
            $0.supportsAutomaticSync && now().timeIntervalSince(lastAttempts[$0] ?? .distantPast) >= $0.refreshInterval
        }
        await refresh(platforms: due, allowInteraction: false)
    }

    private func refresh(platforms: [CreditPlatform], allowInteraction: Bool) async {
        let tasks = platforms.map { platform in
            Task { await refresh(platform: platform, allowInteraction: allowInteraction) }
        }
        for task in tasks { await task.value }
    }

    private func refresh(platform: CreditPlatform, allowInteraction: Bool) async {
        guard platform.supportsAutomaticSync else { return }
        if let running = refreshTasks[platform] {
            await running.task.value
            if running.revision == credentialRevisions[platform, default: 0], running.source == billingSource(for: platform) { return }
            // A saved/replaced key must be tested even if the old key had an in-flight request.
            await refresh(platform: platform, allowInteraction: allowInteraction)
            return
        }
        let revision = credentialRevisions[platform, default: 0]
        let task = Task {
            await performRefresh(platform: platform, revision: revision, allowInteraction: allowInteraction)
            refreshTasks[platform] = nil
            isRefreshing = !refreshTasks.isEmpty
        }
        refreshTasks[platform] = (revision, billingSource(for: platform), task)
        isRefreshing = true
        await task.value
    }

    private func performRefresh(platform: CreditPlatform, revision: Int, allowInteraction: Bool) async {
        lastAttempts[platform] = now()
        var credential = ""
        do {
            guard let key = try keychain.get(for: platform, allowInteraction: allowInteraction), !key.isEmpty else {
                providerStatuses[platform] = .notConfigured(platform.credentialHint)
                updateRefreshError()
                save()
                return
            }
            credential = key
            let source = billingSource(for: platform)
            if source == "" {
                providerStatuses[platform] = .notConfigured("尚未設定 BigQuery Billing Export 表名")
                updateRefreshError()
                save()
                return
            }
            providerStatuses[platform] = .syncing
            if platform == .elevenLabs {
                let balance = try await ElevenLabsProvider(client: client, now: now).fetchBalance(apiKey: key)
                guard revision == credentialRevisions[platform, default: 0] else { return }
                CostSynchronizer.apply(balance, to: &data)
                providerStatuses[platform] = .subscription(balance)
            } else {
                let start = CostSynchronizer.startDate(for: platform, in: data, now: now(), source: source)
                let usage: ProviderUsage
                switch platform {
                case .openAI:
                    usage = try await OpenAIProvider(client: client, now: now).fetchUsage(apiKey: key, since: start)
                case .claude:
                    usage = try await ClaudeProvider(client: client, now: now).fetchUsage(apiKey: key, since: start)
                case .gemini:
                    usage = try await GeminiBigQueryProvider(session: client.session, now: now).fetchUsage(
                        serviceAccountJSON: key, billingTable: source ?? "", since: start
                    )
                case .elevenLabs, .lovable, .notion:
                    return
                }
                guard revision == credentialRevisions[platform, default: 0] else { return }
                if platform == .gemini && source != GeminiSettings.billingTable.trimmingCharacters(in: .whitespacesAndNewlines) {
                    providerStatuses[platform] = .notConfigured("表名已變更，請重新同步")
                    return
                }
                let firstSync = data.costSyncStates?[platform] == nil || data.costSyncStates?[platform]?.source != source
                CostSynchronizer.apply(usage, since: start, source: source, to: &data)
                let hasEntry = data.entries.contains {
                    !$0.isArchived && $0.platform == platform && $0.remainingAmount > 0
                        && $0.receivedAt <= usage.fetchedAt && $0.unit.caseInsensitiveCompare(usage.currency) == .orderedSame
                }
                providerStatuses[platform] = .success(
                    cost: usage.cumulativeCost, currency: usage.currency, date: usage.fetchedAt,
                    needsCreditEntry: !hasEntry, firstSync: firstSync
                )
            }
            data.lastRefreshAt = now()
        } catch {
            guard revision == credentialRevisions[platform, default: 0] else { return }
            var message = error.localizedDescription
            if !credential.isEmpty { message = message.replacingOccurrences(of: credential, with: "[已隱藏金鑰]") }
            providerStatuses[platform] = .failed(message)
        }
        updateRefreshError()
        saveAndCheckNotifications()
    }

    private func updateRefreshError() {
        let errors = CreditPlatform.allCases.compactMap { platform -> String? in
            guard let status = providerStatuses[platform], status.state == .failed else { return nil }
            return "\(platform.rawValue)：\(status.message)"
        }
        data.lastRefreshError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private func billingSource(for platform: CreditPlatform) -> String? {
        platform == .gemini ? GeminiSettings.billingTable.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    func checkNotifications(now: Date = .now) async {
        for entry in activeEntries where entry.remainingAmount > 0 && !entry.isAutomaticSubscription {
            let days = entry.daysUntilExpiration(now: now)
            guard let stage = NotificationMilestone.stage(forDaysRemaining: days) else { continue }
            let key = "\(entry.id.uuidString)-\(stage)"
            guard !data.deliveredNotifications.contains(key) else { continue }
            await notifications.sendExpirationNotification(for: entry, days: days)
            data.deliveredNotifications.insert(key)
        }
        save()
    }

    private func scheduleRefresh() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshIfNeeded() }
            }
        Task { [weak self] in await self?.refreshIfNeeded() }
    }

    private func saveAndCheckNotifications() {
        save()
        Task { await checkNotifications() }
    }

    private func save() { try? persistence.save(data) }
}

struct ProviderSyncStatus: Equatable, Sendable {
    enum State: Equatable, Sendable { case notConfigured, syncing, success, failed }
    var state: State
    var message: String
    var cumulativeCost: Decimal?
    var currency: String?
    var fetchedAt: Date?

    static func notConfigured(_ message: String) -> Self {
        Self(state: .notConfigured, message: message)
    }
    static let syncing = Self(state: .syncing, message: "正在連線官方帳務 API…")
    static func failed(_ message: String) -> Self {
        Self(state: .failed, message: message)
    }
    static func success(cost: Decimal, currency: String, date: Date, needsCreditEntry: Bool, firstSync: Bool = false) -> Self {
        let suffix = needsCreditEntry ? "；請新增目前剩餘額度與到期日" : (firstSync ? "；已建立基準，之後扣除新增花費" : "；剩餘額度已更新")
        return Self(
            state: .success,
            message: "API 連線成功，追蹤期間花費 \(cost.formatted()) \(currency)\(suffix)",
            cumulativeCost: cost,
            currency: currency,
            fetchedAt: date
        )
    }
}

extension ProviderSyncStatus {
    static func subscription(_ balance: ElevenLabsBalance) -> Self {
        let reset = balance.resetsAt.map { "；下次重設：\($0.formatted(date: .abbreviated, time: .shortened))" }
            ?? "；API 未提供下次重設時間"
        return Self(state: .success, message: "剩餘 \(balance.remaining.formatted()) / \(balance.limit.formatted()) credits\(reset)", fetchedAt: balance.fetchedAt)
    }
}

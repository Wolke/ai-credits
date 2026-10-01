import Foundation
import Combine
import AppKit

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var data: AppData
    @Published private(set) var isRefreshing = false
    @Published private(set) var persistenceError: String?
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
    // Reuse only the just-saved value for its immediate test, then return to Keychain reads.
    private var pendingCredentials: [CreditPlatform: (value: String, expiresAt: Date)] = [:]

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
        self.providerStatuses = data.providerSyncStatuses ?? [:]
        let loadedEntries = data.entries
        for platform in CreditPlatform.allCases where platform.usesCostEstimates {
            recalculateOriginalBalance(for: platform)
        }
        for platform in CreditPlatform.allCases where platform.supportsAutomaticSync {
            if providerStatuses[platform]?.state == .syncing {
                providerStatuses[platform]?.state = .failed
                providerStatuses[platform]?.message = "上次同步未完成（App 已結束或重新啟動）；請重新測試"
                appendEvent(platform: platform, message: "上次同步中斷，保留原有額度")
            }
        }
        if data.providerSyncStatuses != nil { updateRefreshError() }
        if data.entries != loadedEntries { save() }
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

    var balanceSummaries: [PlatformBalanceSummary] {
        PlatformBalanceSummary.all(in: activeEntries)
    }

    func upsert(_ entry: CreditEntry) {
        if let index = data.entries.firstIndex(where: { $0.id == entry.id }) {
            data.entries[index] = entry
        } else {
            data.entries.append(entry)
        }
        recalculateOriginalBalance(for: entry.platform)
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
        data.entries[index].calculatesFromOriginal = false
        saveAndCheckNotifications()
    }

    func reconciliation(for platform: CreditPlatform) -> BalanceReconciliation? {
        guard data.costSyncStates?[platform]?.source == billingSource(for: platform) else { return nil }
        return BalanceReconciliation.preview(for: platform, in: data)
    }

    func reconcile(_ proposal: BalanceReconciliation) throws {
        guard refreshTasks[proposal.entry.platform] == nil,
              reconciliation(for: proposal.entry.platform) == proposal else { throw ReconciliationError.changed }
        var updated = data
        try proposal.apply(to: &updated)
        // Save before publishing, so a disk error cannot look like a completed correction.
        try persistence.save(updated)
        data = updated
        recalculateOriginalBalance(for: proposal.entry.platform)
        appendEvent(platform: proposal.entry.platform, message: "已按原始總額校正並啟用自動重算：\(proposal.entry.originalBalanceFormula(cost: proposal.cost))；原帳面 \(proposal.entry.remainingAmount.formatted())")
        saveAndCheckNotifications()
    }

    private func recalculateOriginalBalance(for platform: CreditPlatform) {
        guard data.costSyncStates?[platform]?.source == billingSource(for: platform),
              CostSynchronizer.recalculateOriginalBalance(for: platform, in: &data) != nil,
              let calculation = reconciliation(for: platform) else { return }
        // Recomputing cached data is not a new API success; retain any current connection error.
        if providerStatuses[platform]?.state == .success { setStatus(.calculated(calculation), for: platform) }
    }

    func setAPIKey(_ key: String, for platform: CreditPlatform) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // Comparing with the previous key is optional; never prompt just to compare.
        let previous = try? keychain.get(for: platform, allowInteraction: false)
        if trimmed.isEmpty {
            try keychain.delete(for: platform)
        } else {
            try keychain.set(trimmed, for: platform)
        }
        pendingCredentials[platform] = trimmed.isEmpty ? nil : (trimmed, now().addingTimeInterval(60))
        if trimmed != previous {
            credentialRevisions[platform, default: 0] += 1
            data.costSyncStates?[platform] = nil
            data.providerLastCosts[platform] = nil
        }
        setStatus(trimmed.isEmpty ? .notConfigured(platform.credentialHint) : ProviderSyncStatus(state: .idle, message: "金鑰已儲存，等待測試"), for: platform)
        appendEvent(platform: platform, message: trimmed.isEmpty ? "已清除金鑰" : "金鑰已儲存，尚未測試")
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
        let attemptedAt = now()
        lastAttempts[platform] = attemptedAt
        let previous = providerStatuses[platform]
        var pending = ProviderSyncStatus(state: .syncing, message: "正在檢查金鑰；尚未發起 HTTP 請求")
        pending.attemptedAt = attemptedAt
        pending.lastSuccessAt = previous?.lastSuccessAt ?? previous?.fetchedAt
        pending.trigger = allowInteraction ? "手動" : "自動"
        providerStatuses[platform] = pending
        appendEvent(platform: platform, message: "\(pending.trigger ?? "")同步開始，正在檢查金鑰")
        save()
        defer {
            updateRefreshError()
            saveAndCheckNotifications()
        }
        var credential = ""
        do {
            let pendingKey = pendingCredentials.removeValue(forKey: platform)
            let storedKey: String?
            if let pendingKey, pendingKey.expiresAt > now() {
                storedKey = pendingKey.value
            } else {
                storedKey = try keychain.get(for: platform, allowInteraction: allowInteraction)
            }
            guard let key = storedKey, !key.isEmpty else {
                setStatus(.notConfigured(platform.credentialHint + "；未發起 API 請求"), for: platform)
                appendEvent(platform: platform, message: "略過：" + platform.credentialHint + "；未發起 API 請求")
                return
            }
            credential = key
            let source = billingSource(for: platform)
            if source == "" {
                setStatus(.notConfigured("尚未設定 BigQuery Billing Export 表名；未發起 API 請求"), for: platform)
                appendEvent(platform: platform, message: "略過：尚未設定 BigQuery 表名；未發起 API 請求")
                return
            }
            var monitoredClient = client
            let originalObserver = client.onEvent
            monitoredClient.onEvent = { [weak self] event in
                await originalObserver?(event)
                await self?.recordHTTPEvent(event, platform: platform, revision: revision, credential: key)
            }
            if platform == .elevenLabs {
                let balance = try await ElevenLabsProvider(client: monitoredClient, now: now).fetchBalance(apiKey: key)
                guard revision == credentialRevisions[platform, default: 0] else { return }
                CostSynchronizer.apply(balance, to: &data)
                setStatus(.subscription(balance), for: platform)
            } else {
                let start = CostSynchronizer.startDate(for: platform, in: data, now: now(), source: source)
                let usage: ProviderUsage
                switch platform {
                case .openAI:
                    usage = try await OpenAIProvider(client: monitoredClient, now: now).fetchUsage(apiKey: key, since: start)
                case .claude:
                    usage = try await ClaudeProvider(client: monitoredClient, now: now).fetchUsage(apiKey: key, since: start)
                case .gemini:
                    usage = try await GeminiBigQueryProvider(client: monitoredClient, now: now).fetchUsage(
                        serviceAccountJSON: key, billingTable: source ?? "", since: start
                    )
                case .elevenLabs, .lovable, .notion:
                    return
                }
                guard revision == credentialRevisions[platform, default: 0] else { return }
                if platform == .gemini && source != GeminiSettings.billingTable.trimmingCharacters(in: .whitespacesAndNewlines) {
                    setStatus(.notConfigured("表名已變更，請重新同步"), for: platform)
                    appendEvent(platform: platform, message: "設定已變更，未套用這次回應")
                    return
                }
                let firstSync = data.costSyncStates?[platform] == nil || data.costSyncStates?[platform]?.source != source
                let deducted = CostSynchronizer.apply(usage, since: start, source: source, to: &data)
                let hasEntry = data.entries.contains {
                    !$0.isArchived && $0.platform == platform && $0.daysUntilExpiration(now: usage.fetchedAt) >= 0
                        && $0.receivedAt <= usage.fetchedAt && $0.unit.caseInsensitiveCompare(usage.currency) == .orderedSame
                }
                if data.entries.contains(where: { $0.platform == platform && !$0.isArchived && $0.usesOriginalCostBalance }) {
                    guard let calculation = reconciliation(for: platform), calculation.entry.usesOriginalCostBalance else {
                        setStatus(.failed("API 已讀取花費，但原始額度自動計算需要同期間、同幣別的單筆額度；此次未改動餘額。請檢查額度日期與計算方式。"), for: platform)
                        appendEvent(platform: platform, message: "額度計算未完成：多筆額度或花費期間不符")
                        return
                    }
                    setStatus(.calculated(calculation), for: platform)
                } else {
                    setStatus(.success(
                        cost: usage.cumulativeCost, currency: usage.currency, since: start, date: usage.fetchedAt, deducted: deducted,
                        needsCreditEntry: !hasEntry, firstSync: firstSync
                    ), for: platform)
                }
            }
            data.lastRefreshAt = now()
            providerStatuses[platform]?.lastSuccessAt = now()
            appendEvent(platform: platform, message: "同步成功：" + (providerStatuses[platform]?.message ?? ""))
        } catch {
            guard revision == credentialRevisions[platform, default: 0] else { return }
            let detail = error is DecodingError ? "API 已回應，但資料格式不符，未更新額度。請查看 HTTP 回應紀錄。" : error.localizedDescription
            let message = DiagnosticText.redact(detail, secrets: [credential])
            setStatus(.failed(message), for: platform)
            appendEvent(platform: platform, message: "同步失敗：" + message)
        }
    }

    func status(for platform: CreditPlatform) -> ProviderSyncStatus {
        providerStatuses[platform] ?? .idle
    }

    private func setStatus(_ status: ProviderSyncStatus, for platform: CreditPlatform) {
        let previous = providerStatuses[platform]
        var status = status
        status.attemptedAt = previous?.attemptedAt
        status.lastSuccessAt = previous?.lastSuccessAt ?? previous?.fetchedAt
        status.requestCount = previous?.requestCount ?? 0
        status.lastHTTPStatus = previous?.lastHTTPStatus
        status.trigger = previous?.trigger
        providerStatuses[platform] = status
    }

    private func recordHTTPEvent(_ event: BillingRequestEvent, platform: CreditPlatform, revision: Int, credential: String) {
        guard revision == credentialRevisions[platform, default: 0] else { return }
        var status = status(for: platform)
        if event.phase == .started {
            status.requestCount += 1
            status.lastHTTPStatus = nil
        }
        if let code = event.statusCode { status.lastHTTPStatus = code }
        status.message = DiagnosticText.redact(event.message, secrets: [credential])
        providerStatuses[platform] = status
        appendEvent(platform: platform, message: status.message, endpoint: DiagnosticText.redact(event.endpoint, secrets: [credential]))
        save()
    }

    private func appendEvent(platform: CreditPlatform, message: String, endpoint: String? = nil) {
        var events = data.syncEvents ?? []
        events.append(SyncEvent(platform: platform, date: now(), message: DiagnosticText.redact(message), endpoint: endpoint))
        data.syncEvents = Array(events.suffix(120))
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

    private func save() {
        data.providerSyncStatuses = providerStatuses
        do {
            try persistence.save(data)
            persistenceError = nil
        } catch {
            persistenceError = "無法儲存額度與同步紀錄：\(error.localizedDescription)"
        }
    }
}

import Foundation

struct ProviderSyncStatus: Equatable, Codable, Sendable {
    enum State: String, Equatable, Codable, Sendable { case idle, notConfigured, syncing, success, failed }
    var state: State
    var message: String
    var cumulativeCost: Decimal?
    var currency: String?
    var fetchedAt: Date?
    var attemptedAt: Date?
    var lastSuccessAt: Date?
    var requestCount = 0
    var lastHTTPStatus: Int?
    var trigger: String?

    static let idle = Self(state: .idle, message: "尚未檢查；按「立即測試」確認金鑰與連線")

    var stateLabel: String {
        switch state {
        case .idle: "尚未測試"
        case .notConfigured: "未設定"
        case .syncing: "同步中"
        case .success: "成功"
        case .failed: "失敗"
        }
    }

    var requestSummary: String {
        guard attemptedAt != nil else { return "尚無 API 呼叫紀錄" }
        let count = requestCount == 0 ? "本次未發起 HTTP 請求" : "本次已發起 \(requestCount) 次 HTTP 請求（含分頁與重試）"
        return count + (lastHTTPStatus.map { "；最後回應 HTTP \($0)" } ?? "")
    }

    static func notConfigured(_ message: String) -> Self {
        Self(state: .notConfigured, message: message)
    }
    static let syncing = Self(state: .syncing, message: "正在連線官方帳務 API…")
    static func failed(_ message: String) -> Self {
        Self(state: .failed, message: message)
    }
    static func success(cost: Decimal, currency: String, since: Date, date: Date, deducted: Decimal, needsCreditEntry: Bool, firstSync: Bool = false) -> Self {
        let suffix = needsCreditEntry ? "；尚無同幣別的有效額度，請新增目前剩餘額度與到期日" : (firstSync ? "；首次同步保留輸入的餘額，尚未扣除歷史花費" : "；餘額為本機估算值")
        return Self(
            state: .success,
            message: "API 累計花費 \(cost.formatted()) \(currency)（\(since.formatted(date: .numeric, time: .omitted))～\(date.formatted(date: .numeric, time: .omitted))）；本次從帳面扣除 \(deducted.formatted()) \(currency)\(suffix)",
            cumulativeCost: cost,
            currency: currency,
            fetchedAt: date
        )
    }

    static func calculated(_ calculation: BalanceReconciliation) -> Self {
        Self(state: .success,
             message: "原始額度 − API 累計花費：\(calculation.entry.originalBalanceFormula(cost: calculation.cost))（\(calculation.state.since.formatted(date: .numeric, time: .omitted))～\(calculation.state.fetchedAt.formatted(date: .numeric, time: .omitted))）；每次同步自動重算",
             cumulativeCost: calculation.cost, currency: calculation.state.currency, fetchedAt: calculation.state.fetchedAt)
    }
}

extension ProviderSyncStatus {
    static func subscription(_ balance: ElevenLabsBalance) -> Self {
        let reset = balance.resetsAt.map { "；下次重設：\($0.formatted(date: .abbreviated, time: .shortened))" }
            ?? "；API 未提供下次重設時間"
        return Self(state: .success, message: "剩餘 \(balance.remaining.formatted()) / \(balance.limit.formatted()) credits\(reset)", fetchedAt: balance.fetchedAt)
    }
}

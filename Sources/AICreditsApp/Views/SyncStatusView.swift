import SwiftUI

struct SyncStatusView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedPlatform: CreditPlatform?

    private var events: [SyncEvent] {
        (store.data.syncEvents ?? []).reversed().filter { selectedPlatform == nil || $0.platform == selectedPlatform }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API 狀態與紀錄").font(.title2.bold())
                        Text("v\(AppVersion.short) · 保留最近 120 筆紀錄，重新開啟 App 後仍可查看。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                    Button("全部立即測試") { Task { await store.refresh() } }
                        .disabled(store.isRefreshing)
                }

                if let error = store.persistenceError {
                    Label(error, systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
                if let error = store.data.lastRefreshError {
                    GroupBox("目前錯誤") {
                        Text(error).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.red).textSelection(.enabled)
                    }
                }

                ForEach(CreditPlatform.allCases) { platform in
                    GroupBox {
                        HStack(alignment: .top) {
                            if platform.supportsAutomaticSync {
                                ProviderStatusRow(platform: platform, status: store.status(for: platform))
                                Spacer(minLength: 12)
                                Button("立即測試") { Task { await store.refresh(platform: platform) } }
                                    .disabled(store.status(for: platform).state == .syncing)
                            } else {
                                Label("\(platform.rawValue)：手動管理", systemImage: "pencil")
                                Spacer()
                                Text("不會呼叫 API").foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                }

                HStack {
                    Text("呼叫紀錄").font(.headline)
                    Spacer()
                    Picker("平台", selection: $selectedPlatform) {
                        Text("全部").tag(nil as CreditPlatform?)
                        ForEach(CreditPlatform.allCases.filter(\.supportsAutomaticSync)) {
                            Text($0.rawValue).tag(Optional($0))
                        }
                    }.frame(width: 220)
                }
                Text("HTTP 請求數會計入分頁、重試及 Google 登入；收到 HTTP 200 後仍需成功解析資料才會標示同步成功。")
                    .font(.caption).foregroundStyle(.secondary)
                if events.isEmpty {
                    Text("尚無紀錄，按「立即測試」開始。")
                        .foregroundStyle(.secondary).padding(.vertical, 12)
                }
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(event.date.formatted(date: .abbreviated, time: .standard)) · \(event.platform.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(event.message).font(.callout)
                            if let endpoint = event.endpoint {
                                Text(endpoint).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

struct ProviderStatusRow: View {
    @EnvironmentObject private var store: AppStore
    @State private var reconciliation: BalanceReconciliation?
    let platform: CreditPlatform
    let status: ProviderSyncStatus?

    var body: some View {
        let status = status ?? .idle
        HStack(alignment: .top, spacing: 8) {
            if status.state == .syncing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: status.symbol).foregroundStyle(status.color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(platform.rawValue) · API \(status.stateLabel)").font(.callout.bold())
                    .foregroundStyle(status.color)
                Text(status.message).font(.caption)
                    .foregroundStyle(status.state == .failed ? Color.red : Color.secondary)
                if platform.usesCostEstimates, let state = store.data.costSyncStates?[platform] {
                    if let summary = store.balanceSummaries.first(where: { $0.platform == platform && $0.currency == state.currency.uppercased() }) {
                        PlatformBalanceBreakdown(summary: summary)
                    } else {
                        Text("尚無此幣別的已發放額度").font(.caption)
                    }
                    if let calculation = store.activeReconciliation(for: platform) {
                        Text("未到期原始額度 − 期間花費：\(calculation.formula)")
                            .font(.caption.bold())
                        Text("花費期間：\(calculation.state.since.formatted(date: .numeric, time: .omitted))～\(calculation.state.fetchedAt.formatted(date: .numeric, time: .shortened))。依已儲存 API 花費估算；重疊期間只扣一次，已到期額度不參與抵扣。")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if let proposal = store.reconciliation(for: platform) {
                        if proposal.entry.usesOriginalCostBalance {
                            Text("自動計算：原始額度 − API 累計花費")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Button("校正餘額並啟用自動計算…") { reconciliation = proposal }
                                .font(.caption).disabled(status.state == .syncing)
                        }
                    } else if ActiveBalanceReconciliation.isEnabled(for: platform, in: store.data, at: .now) {
                        Text("有效額度或日期已變更，請同步從最早有效額度取得日至今的花費。")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("OpenAI 可將所有有效額度開啟自動計算，以未到期原始總額扣除期間花費；其他情況請依官方帳務頁校正。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(status.requestSummary).font(.caption).foregroundStyle(.secondary)
                if let date = status.attemptedAt {
                    Text("最近嘗試：\(date.formatted(date: .abbreviated, time: .standard))（\(status.trigger ?? "同步")）")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(status.lastSuccessAt.map { "最近成功：\($0.formatted(date: .abbreviated, time: .standard))" } ?? "尚無成功同步紀錄")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        .sheet(item: $reconciliation) { proposal in
            BalanceReconciliationView(proposal: proposal)
        }
    }
}

private struct PlatformBalanceBreakdown: View {
    let summary: PlatformBalanceSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(summary.totalLabel)（\(summary.availableEntries.count) 筆）：\(summary.remaining.formatted()) \(summary.currency)")
                .font(.caption.bold())
            if summary.availableEntries.count > 1 {
                Text(summary.sumFormula).font(.caption.monospacedDigit())
                ForEach(summary.availableEntries) { entry in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.expiresAt.formatted(date: .numeric, time: .omitted)) 到期 · \(entry.name.isEmpty ? "未命名額度" : entry.name)")
                            if let formula = entry.balanceFormula {
                                Text(formula).foregroundStyle(.secondary)
                            } else {
                                Text("原始 \(entry.originalAmount.formatted()) \(entry.unit)").foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 12)
                        Text("本筆 \(entry.remainingAmount.formatted()) \(entry.unit)").monospacedDigit()
                    }
                    .font(.caption2)
                }
            }
            if !summary.expiredEntries.isEmpty {
                Text("另有 \(summary.expiredEntries.count) 筆已過期，未計入上述合計。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if summary.hasPendingCalculation {
                Text("自動重算尚未完成，下列仍為上次餘額。請完成 API 同步以取得完整期間花費。")
                    .font(.caption).foregroundStyle(.orange)
            } else if summary.usesManualBaseline {
                Text("餘額沿用手動基準，只扣後續新增花費；API 讀取成功不代表歷史餘額已核對。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

extension ProviderSyncStatus {
    var symbol: String {
        switch state {
        case .idle: "questionmark.circle"
        case .notConfigured: "key.slash"
        case .syncing: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch state {
        case .idle, .notConfigured: .secondary
        case .syncing: .blue
        case .success: .green
        case .failed: .red
        }
    }
}

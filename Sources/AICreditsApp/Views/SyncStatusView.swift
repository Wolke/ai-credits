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
                Text("\(platform.rawValue) · \(status.stateLabel)").font(.callout.bold())
                    .foregroundStyle(status.color)
                Text(status.message).font(.caption)
                    .foregroundStyle(status.state == .failed ? Color.red : Color.secondary)
                if platform.usesCostEstimates, let state = store.data.costSyncStates?[platform] {
                    let remaining = store.currentEntries.filter {
                        $0.platform == platform && $0.unit.caseInsensitiveCompare(state.currency) == .orderedSame
                    }.reduce(Decimal.zero) { $0 + $1.remainingAmount }
                    Text("帳面預估剩餘：\(remaining.formatted()) \(state.currency)").font(.caption.bold())
                    if let proposal = store.reconciliation(for: platform) {
                        Button("校正餘額…") { reconciliation = proposal }
                            .font(.caption).disabled(status.state == .syncing)
                    } else {
                        Text("若有多筆額度或花費期間不同，請至「管理全部」依官方帳務頁逐筆校正餘額。")
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

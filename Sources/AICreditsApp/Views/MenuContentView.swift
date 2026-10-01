import SwiftUI
import AppKit

struct MenuContentView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI Credits").font(.headline)
                Text("v\(AppVersion.short)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)
                .help("立即同步")
            }

            if store.currentEntries.isEmpty {
                ContentUnavailableView("尚無額度", systemImage: "creditcard", description: Text("新增第一筆贈送的 AI credits"))
                    .frame(height: 150)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.balanceSummaries.filter { !$0.availableEntries.isEmpty }) { summary in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("\(summary.platform.rawValue) 合計（\(summary.availableEntries.count) 筆）")
                                    Spacer()
                                    Text("\(summary.remaining.formatted()) \(summary.currency)").monospacedDigit()
                                }
                                .font(.caption.bold())
                                ForEach(summary.availableEntries) { entry in
                                    CreditRow(entry: entry)
                                }
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 400)
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(store.isRefreshing ? "API 同步中…" : "API 同步狀態").font(.caption.bold())
                    Spacer()
                    Button("查看紀錄") { openWindow(id: "sync-status") }
                        .buttonStyle(.link).font(.caption)
                }
                ForEach(CreditPlatform.allCases.filter(\.supportsAutomaticSync)) { platform in
                    let status = store.status(for: platform)
                    HStack(spacing: 6) {
                        Image(systemName: status.symbol).foregroundStyle(status.color)
                        Text(platform.rawValue)
                        Spacer()
                        Text(status.stateLabel).foregroundStyle(status.color)
                    }
                    .font(.caption)
                }
                Text("Lovable、Notion：手動管理，不會呼叫 API")
                    .font(.caption2).foregroundStyle(.secondary)
                if store.data.lastRefreshError != nil || store.persistenceError != nil {
                    Button("同步有錯誤，查看完整原因") { openWindow(id: "sync-status") }
                        .buttonStyle(.link).foregroundStyle(.red).font(.caption)
                }
            }

            Divider()
            HStack {
                Button("新增額度") { openWindow(id: "new-credit") }
                Spacer()
                Button("管理全部") { openWindow(id: "credits") }
                Button("設定") { openWindow(id: "settings") }
            }
            HStack {
                Spacer()
                Button("退出 AI Credits") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 380)
        .task { await store.refreshIfNeeded() }
    }
}

enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開發版"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}

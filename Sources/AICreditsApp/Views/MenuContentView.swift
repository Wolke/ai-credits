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
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(store.isRefreshing ? .degrees(360) : .zero)
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)
                .help("立即同步")
            }

            if store.currentEntries.isEmpty {
                ContentUnavailableView("尚無額度", systemImage: "creditcard", description: Text("新增第一筆贈送的 AI credits"))
                    .frame(height: 150)
            } else {
                ForEach(store.currentEntries.prefix(5)) { entry in
                    CreditRow(entry: entry)
                }
            }

            if let error = store.data.lastRefreshError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            } else if let date = store.data.lastRefreshAt {
                Text("上次同步：\(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
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
        .frame(width: 360)
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

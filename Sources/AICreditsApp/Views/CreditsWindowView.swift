import SwiftUI

struct CreditsWindowView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @State private var editingEntry: CreditEntry?
    @State private var showingNewEntry = false
    @State private var showingExpired = false
    @State private var deletingEntry: CreditEntry?

    private var displayedEntries: [CreditEntry] {
        showingExpired ? store.issuedEntries : store.currentEntries
    }

    var body: some View {
        NavigationSplitView {
            List(CreditPlatform.allCases) { platform in
                Label(platform.rawValue, systemImage: platform.symbol)
            }
            .navigationTitle("平台")
        } detail: {
            Group {
                if displayedEntries.isEmpty {
                    ContentUnavailableView(
                        store.issuedEntries.isEmpty ? "還沒有已發放額度" : "沒有有效額度",
                        systemImage: "sparkles",
                        description: Text(store.issuedEntries.isEmpty ? "排程額度會在發放日自動出現。" : "可開啟「顯示已過期」查看舊額度。")
                    )
                } else {
                    List {
                        ForEach(store.balanceSummaries.filter { showingExpired || !$0.availableEntries.isEmpty }) { summary in
                            Section {
                                ForEach(showingExpired ? summary.entries : summary.availableEntries) { entry in
                                    HStack {
                                        CreditRow(entry: entry)
                                            .contentShape(Rectangle())
                                            .onTapGesture { if !entry.isAutomaticSubscription { editingEntry = entry } }
                                        Button(role: .destructive) { deletingEntry = entry } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("永久刪除")
                                    }
                                    .contextMenu {
                                        Button("編輯") { editingEntry = entry }
                                            .disabled(entry.isAutomaticSubscription)
                                        Button("封存") { store.archive(id: entry.id) }
                                        Divider()
                                        Button("永久刪除", role: .destructive) { deletingEntry = entry }
                                    }
                                }
                            } header: {
                                Text("\(summary.platform.rawValue) · \(summary.totalLabel)（\(summary.availableEntries.count) 筆）：\(summary.remaining.formatted()) \(summary.currency)")
                            }
                        }
                    }
                }
            }
            .navigationTitle("AI Credits")
            .toolbar {
                Button("API 狀態", systemImage: "network") { openWindow(id: "sync-status") }
                Toggle(isOn: $showingExpired) {
                    Label("顯示已過期", systemImage: "clock.arrow.circlepath")
                }
                .toggleStyle(.button)
                Button { Task { await store.refresh() } } label: { Label("同步", systemImage: "arrow.clockwise") }
                    .disabled(store.isRefreshing)
                Button { showingNewEntry = true } label: { Label("新增", systemImage: "plus") }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task { await store.refreshIfNeeded() }
        .sheet(isPresented: $showingNewEntry) {
            CreditEditorView { entries in entries.forEach(store.upsert) }
        }
        .sheet(item: $editingEntry) { entry in
            CreditEditorView(entry: entry) { entries in entries.forEach(store.upsert) }
        }
        .confirmationDialog(
            "永久刪除這筆額度？",
            isPresented: Binding(
                get: { deletingEntry != nil },
                set: { if !$0 { deletingEntry = nil } }
            ),
            presenting: deletingEntry
        ) { entry in
            Button("永久刪除", role: .destructive) {
                store.delete(id: entry.id)
                deletingEntry = nil
            }
            Button("取消", role: .cancel) { deletingEntry = nil }
        } message: { entry in
            Text("將刪除 \(entry.platform.rawValue)「\(entry.name.isEmpty ? "未命名來源" : entry.name)」，此動作無法復原。")
        }
    }
}

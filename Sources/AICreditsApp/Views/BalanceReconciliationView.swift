import SwiftUI

struct BalanceReconciliationView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let proposal: BalanceReconciliation
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("以原始總額減去 API 累計花費，校正餘額並啟用每次同步自動重算。")
                Text("適用於「原始額度」是最初獲得的完整總額，且此期間的花費全部由這筆額度支付。若你輸入的是當時剩餘額度，請取消並依官方帳務頁編輯餘額。")
                    .font(.callout).foregroundStyle(.secondary)
                GroupBox {
                    VStack(spacing: 10) {
                        LabeledContent("原始總額", value: amount(proposal.entry.originalAmount))
                        LabeledContent("API 累計花費", value: amount(proposal.cost))
                        LabeledContent("目前帳面剩餘", value: amount(proposal.entry.remainingAmount))
                        Divider()
                        LabeledContent("校正後預估剩餘", value: amount(proposal.remaining)).bold()
                    }.padding(8)
                }
                Text("花費期間：\(proposal.state.since.formatted(date: .numeric, time: .shortened))～\(proposal.state.fetchedAt.formatted(date: .numeric, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("每次同步與重新開啟 App 都會以原始總額重算；重複刷新不會重複扣款。API 下修花費時，餘額也會修正。超過原始額度時，剩餘顯示為 0。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .padding(20)
            .navigationTitle("\(proposal.entry.platform.rawValue) 餘額校正")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("校正並啟用自動計算") {
                        do {
                            try store.reconcile(proposal)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(store.status(for: proposal.entry.platform).state == .syncing)
                }
            }
        }
        .frame(width: 540)
    }

    private func amount(_ value: Decimal) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...4)))) \(proposal.state.currency)"
    }
}

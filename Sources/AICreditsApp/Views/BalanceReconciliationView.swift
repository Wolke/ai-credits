import SwiftUI

struct BalanceReconciliationView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let proposal: BalanceReconciliation
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("以原始總額減去累計花費，重新計算這筆額度。")
                Text("適用於「原始額度」是最初獲得的完整總額，且此期間的花費全部由這筆額度支付。若你輸入的是當時剩餘額度，請取消並依官方帳務頁編輯餘額。")
                    .font(.callout).foregroundStyle(.secondary)
                GroupBox {
                    VStack(spacing: 10) {
                        LabeledContent("原始總額", value: amount(proposal.entry.originalAmount))
                        LabeledContent("已計入累計花費", value: amount(proposal.state.cumulativeCost))
                        LabeledContent("目前帳面剩餘", value: amount(proposal.entry.remainingAmount))
                        Divider()
                        LabeledContent("校正後預估剩餘", value: amount(proposal.remaining)).bold()
                    }.padding(8)
                }
                Text("花費期間：\(proposal.state.since.formatted(date: .numeric, time: .shortened))～\(proposal.state.fetchedAt.formatted(date: .numeric, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("這是本機估算值。校正後只扣除新增花費，相同的 API 累計金額不會再次扣除。平台下修花費時，已計入花費會保留先前的較高值。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .padding(20)
            .navigationTitle("\(proposal.entry.platform.rawValue) 餘額校正")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("以原始總額重算") {
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

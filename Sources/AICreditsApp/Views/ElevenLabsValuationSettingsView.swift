import SwiftUI

struct ElevenLabsValuationSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var creditsText = ""
    @State private var usdText = ""
    @State private var message: String?

    private var proposal: ElevenLabsUSDValuation? {
        guard let credits = number(creditsText), let usd = number(usdText) else { return nil }
        let value = ElevenLabsUSDValuation(credits: credits, usd: usd)
        return value.isValid ? value : nil
    }
    private var remaining: Decimal? {
        store.balanceSummaries.first { $0.platform == .elevenLabs && $0.currency == "CREDITS" }?.remaining
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("美元換算（選填）").font(.headline)
            Text("依贈送方案標示的價值或帳單填寫換算基準。儲存後顯示預估 USD，並保留 API credits；API 不會自動提供 Grant 的美元價值。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("基準 credits", text: $creditsText, prompt: Text("例如 1000000"))
                Text("credits ≈")
                TextField("對應 USD", text: $usdText, prompt: Text("贈送額度標示價值"))
                Text("USD")
            }
            .textFieldStyle(.roundedBorder)
            if let proposal, let remaining, let estimate = proposal.estimate(for: remaining) {
                Text("預覽：\(remaining.formatted()) ÷ \(proposal.credits.formatted()) × \(proposal.usd.formatted()) ≈ \(estimate.formatted()) USD")
                    .font(.caption).monospacedDigit().textSelection(.enabled)
            }
            HStack {
                Button("儲存 USD 換算") {
                    guard let proposal else { return }
                    do {
                        try store.setElevenLabsUSDValuation(proposal)
                        message = "已儲存，預估美元會隨 API credits 更新"
                    } catch { message = error.localizedDescription }
                }
                .disabled(proposal == nil)
                if store.data.elevenLabsUSDValuation != nil {
                    Button("恢復 credits 顯示") {
                        do {
                            try store.setElevenLabsUSDValuation(nil)
                            usdText = ""
                            message = "已取消美元換算"
                        } catch { message = error.localizedDescription }
                    }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear {
            if let value = store.data.elevenLabsUSDValuation {
                creditsText = NSDecimalNumber(decimal: value.credits).stringValue
                usdText = NSDecimalNumber(decimal: value.usd).stringValue
            } else if let entry = store.data.entries.first(where: { $0.platform == .elevenLabs && $0.isAutomaticSubscription && !$0.isArchived }) {
                creditsText = NSDecimalNumber(decimal: entry.originalAmount).stringValue
            }
        }
    }

    private func number(_ text: String) -> Decimal? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        guard value.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }
}

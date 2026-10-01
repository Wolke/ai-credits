import SwiftUI

struct CreditRow: View {
    let entry: CreditEntry
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.platform.symbol)
                .frame(width: 22, height: 22)
                .foregroundStyle(entry.urgency().color)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.platform.rawValue)
                    .fontWeight(.medium)
                    .foregroundStyle(entry.platform.brandColor)
                    .lineLimit(1)
                if !compact {
                    if !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(entry.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(expirationText)
                        .font(.caption)
                        .foregroundStyle(entry.urgency().color)
                    if let date = entry.lastSyncedAt {
                        Text("更新：\(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(entry.remainingAmount.formatted()) \(entry.unit)")
                    .monospacedDigit()
                if !compact {
                    ProgressView(value: progress)
                        .frame(width: 70)
                        .tint(entry.urgency().color)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var progress: Double {
        let original = NSDecimalNumber(decimal: entry.originalAmount).doubleValue
        guard original > 0 else { return 0 }
        return min(1, max(0, NSDecimalNumber(decimal: entry.remainingAmount).doubleValue / original))
    }

    private var expirationText: String {
        if entry.isAutomaticSubscription {
            guard let reset = entry.subscriptionResetsAt else { return "未提供重設時間" }
            if reset <= .now { return "等待更新本期額度" }
            let hours = max(1, Int(ceil(reset.timeIntervalSinceNow / 3_600)))
            return hours < 24 ? "\(hours) 小時內重設" : "\(entry.daysUntilExpiration()) 天後重設"
        }
        let days = entry.daysUntilExpiration()
        if entry.remainingAmount <= 0 { return "已用完" }
        if days < 0 { return "已到期" }
        if days == 0 { return "今天到期" }
        return "還有 \(days) 天"
    }
}

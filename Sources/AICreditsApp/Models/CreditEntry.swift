import Foundation
import SwiftUI

enum CreditPlatform: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI = "OpenAI"
    case claude = "Claude"
    case gemini = "Gemini"
    case elevenLabs = "ElevenLabs"
    case lovable = "Lovable"
    case notion = "Notion"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .openAI: "sparkles"
        case .claude: "brain.head.profile"
        case .gemini: "diamond"
        case .elevenLabs: "waveform"
        case .lovable: "heart"
        case .notion: "doc.text"
        }
    }
    var supportsAutomaticSync: Bool { [.openAI, .claude, .gemini, .elevenLabs].contains(self) }
    var usesCostEstimates: Bool { [.openAI, .claude, .gemini].contains(self) }
    var refreshInterval: TimeInterval { self == .gemini ? 6 * 60 * 60 : 15 * 60 }
    var credentialHint: String {
        switch self {
        case .gemini: "尚未匯入 Service Account JSON"
        case .elevenLabs: "尚未設定 ElevenLabs API Key"
        default: "尚未設定 Admin API Key"
        }
    }

    var brandColor: Color {
        switch self {
        case .openAI: Color(red: 0.06, green: 0.64, blue: 0.50)
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .gemini: Color(red: 0.26, green: 0.52, blue: 0.96)
        case .elevenLabs: Color(red: 0.45, green: 0.36, blue: 0.85)
        case .lovable: Color(red: 1.00, green: 0.30, blue: 0.55)
        case .notion: .primary
        }
    }
}

enum CreditUrgency: Int, Comparable, Sendable {
    case expired = 0, critical = 1, warning = 2, normal = 3
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct CreditEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var platform: CreditPlatform = .openAI
    var name: String = ""
    var originalAmount: Decimal = 0
    var remainingAmount: Decimal = 0
    var unit: String = "USD"
    var receivedAt: Date = .now
    var expiresAt: Date = Calendar.current.date(byAdding: .month, value: 3, to: .now) ?? .now
    var notes: String = ""
    var isArchived = false
    var lastSyncedAt: Date?
    var syncBaselineAt: Date?
    var syncBaselineCost: Decimal?
    // Optional fields keep existing credits.json files readable.
    var isSubscriptionBalance: Bool?
    var subscriptionResetsAt: Date?
    // Explicitly distinguishes an original grant from an already-spent manual balance.
    var calculatesFromOriginal: Bool?

    var isAutomaticSubscription: Bool { isSubscriptionBalance == true }
    var usesOriginalCostBalance: Bool { platform.usesCostEstimates && calculatesFromOriginal == true }
    var originalBalancePending: Bool { usesOriginalCostBalance && balanceFormula == nil }
    var balanceFormula: String? {
        guard usesOriginalCostBalance, let cost = syncBaselineCost,
              remainingAmount == max(0, originalAmount - cost) else { return nil }
        return originalBalanceFormula(cost: cost)
    }

    func originalBalanceFormula(cost: Decimal) -> String {
        let difference = originalAmount - cost
        let formula = "\(originalAmount.formatted()) − \(cost.formatted()) = \(difference.formatted()) \(unit)"
        return difference < 0 ? formula + "（額度已用完，剩餘 0）" : formula
    }
    var hasKnownExpiration: Bool { !isAutomaticSubscription || subscriptionResetsAt != nil }

    func daysUntilExpiration(now: Date = .now, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: expiresAt)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    func urgency(now: Date = .now, calendar: Calendar = .current) -> CreditUrgency {
        let days = daysUntilExpiration(now: now, calendar: calendar)
        if remainingAmount <= 0 || days < 0 { return .expired }
        if !hasKnownExpiration { return .normal }
        if days <= 7 { return .critical }
        if days <= 30 { return .warning }
        return .normal
    }
}

extension CreditEntry {
    static func monthlyGrantSeries(
        from template: CreditEntry,
        count: Int,
        validityMonths: Int,
        calendar: Calendar = .current
    ) -> [CreditEntry] {
        guard count > 0, validityMonths > 0 else { return [] }

        return (0..<count).compactMap { offset in
            guard let receivedAt = calendar.date(byAdding: .month, value: offset, to: template.receivedAt),
                  let expiresAt = calendar.date(byAdding: .month, value: validityMonths, to: receivedAt)
            else { return nil }

            var entry = template
            entry.id = UUID()
            entry.receivedAt = receivedAt
            entry.expiresAt = expiresAt
            entry.remainingAmount = template.originalAmount
            entry.calculatesFromOriginal = false
            return entry
        }
    }
}

extension CreditUrgency {
    var color: Color {
        switch self {
        case .expired: .secondary
        case .critical: .red
        case .warning: .orange
        case .normal: .green
        }
    }
}
